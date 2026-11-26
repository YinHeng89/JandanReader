import Foundation
import SwiftUI

/// 全 App 统一图片缓存：内存 64MB + 磁盘 512MB 的 URLCache，
/// 覆盖正文大图 / GIF / 缩略图 / 头像，滚动回看和重启后直接命中磁盘，不重复下载。
enum ImageCache {
    static let shared: URLCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let disk = caches.appendingPathComponent("jd_image_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        return URLCache(memoryCapacity: 64 * 1024 * 1024,
                        diskCapacity: 512 * 1024 * 1024,
                        diskPath: disk.path)
    }()

    /// 专用于静态图片请求的 session：带 User-Agent、复用上面的 URLCache。
    /// 不碰 API 的 URLSession.shared（ Cookie / 请求头逻辑独立）。
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = shared
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["User-Agent": JDAPI.userAgent]
        return URLSession(configuration: config)
    }()

    /// 清除磁盘 + 内存图片缓存。
    static func clear() { shared.removeAllCachedResponses() }
}

/// 替代 SwiftUI AsyncImage：走统一缓存 session，避免每次重新下载。
/// 头像 / 缩略图这类小图用，正文大图仍走 InlineAnimatedImageView（逐帧 / mp4 逻辑不同）。
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    // Xcode 27 下 View 内新增 @State 宏会 malformed response，统一放 ObservableObject。
    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: url?.absoluteString) {
            await loader.load(url)
        }
    }
}

@MainActor
final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?

    func load(_ url: URL?) async {
        image = nil
        guard let url else { return }
        let request = URLRequest(url: url)
        // URLCache 查询 + 解码放到后台，滑动列表时避免主线程掉帧。
        let cached = await Task.detached(priority: .userInitiated) {
            ImageCache.shared.cachedResponse(for: request).flatMap { UIImage(data: $0.data) }
        }.value
        if let cached { image = cached; return }
        // 网络请求留在当前 task：列表复用时 `.task(id:)` 的取消能真正中断下载，
        // 不能用 detached task 包住，否则旧请求继续跑还会把旧图写回复用的行。
        guard let (data, response) = try? await ImageCache.session.data(from: url) else { return }
        let loaded = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        ImageCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: data), for: request
        )
        image = loaded
    }
}
