import SwiftUI
import UIKit
import ImageIO

/// 图片流里的图片：按原比例完整显示（不裁剪），GIF 逐帧循环播放。
struct InlineAnimatedImageView: View {
    let url: URL

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var loader = InlineImageLoader()

    var body: some View {
        ZStack {
            InlineImageContainer(url: url, thumbnail: settings.cleanMode, loader: loader)

            if loader.phase == .loading && loader.image == nil {
                ProgressView().tint(Color.accentColor)
            } else if loader.phase == .failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                    Text("图片加载失败").font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 120)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

@MainActor
final class InlineImageLoader: ObservableObject {
    @Published var phase: InlineImagePhase = .loading
    @Published var image: UIImage?
}

enum InlineImagePhase {
    case loading, loaded, failed
}

/// 解码后的图片缓存。GIF 数据可达十几 MB，滚动时重复下载/解码会卡顿。
final class InlineImageCache {
    static let shared = InlineImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 约 160MB 的原始数据量上限，NSCache 会在内存紧张时自动回收。
        cache.totalCostLimit = 160 * 1024 * 1024
        cache.countLimit = 120
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, dataCount: Int, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: dataCount)
    }
}

/// 分享面板的内容。下载原图后给系统分享真实的图片数据，而不是一个链接。
@MainActor
final class ShareState: ObservableObject {
    @Published var item: Any?

    func prepareOriginal(from displayedURL: URL) async {
        // GIF 的 mw600 版本是单帧静态图，分享必须取 large 动画原图。
        let original: URL
        if JDHTML.isGIF(displayedURL) {
            original = JDHTML.animatedGIFURL(displayedURL) ?? displayedURL
        } else {
            original = JDHTML.displayURL(displayedURL, thumbnail: false)
        }
        guard let (data, response) = try? await URLSession.shared.data(from: original),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return }

        // GIF 写成临时文件，分享面板会按动图处理；静态图直接分享 UIImage。
        if String(data: data.prefix(3), encoding: .ascii) == "GIF" {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".gif")
            if (try? data.write(to: file)) != nil { item = file }
        } else if let image = UIImage(data: data) {
            item = image
        } else {
            item = data
        }
    }
}

/// 系统分享面板。
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct InlineImageContainer: UIViewRepresentable {
    let url: URL
    let thumbnail: Bool
    @ObservedObject var loader: InlineImageLoader

    func makeCoordinator() -> Coordinator { Coordinator(loader: loader) }

    func makeUIView(context: Context) -> FittingImageView {
        let view = FittingImageView()
        context.coordinator.load(url, thumbnail: thumbnail, into: view)
        return view
    }

    func updateUIView(_ uiView: FittingImageView, context: Context) {
        // 列表复用 / 设置切换后 URL 可能变，必须重新加载。
        context.coordinator.update(url, thumbnail: thumbnail, into: uiView)
    }

    static func dismantleUIView(_ uiView: FittingImageView, coordinator: Coordinator) {
        coordinator.cancelAll()
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private let loader: InlineImageLoader
        private weak var targetView: FittingImageView?
        private var placeholderTask: URLSessionDataTask?
        private var mainTask: URLSessionDataTask?
        private var currentKey: String?
        private var generation = 0
        private var hasImage = false
        private var animatedApplied = false

        init(loader: InlineImageLoader) { self.loader = loader }

        func cancelAll() {
            placeholderTask?.cancel()
            mainTask?.cancel()
            placeholderTask = nil
            mainTask = nil
        }

        func update(_ url: URL, thumbnail: Bool, into view: FittingImageView) {
            let key = "\(url.absoluteString)|\(thumbnail)"
            guard key != currentKey else { return }
            load(url, thumbnail: thumbnail, into: view)
        }

        func load(_ url: URL, thumbnail: Bool, into view: FittingImageView) {
            currentKey = "\(url.absoluteString)|\(thumbnail)"
            generation += 1
            let gen = generation
            cancelAll()
            targetView = view
            hasImage = false
            animatedApplied = false
            loader.image = nil
            loader.phase = .loading
            view.image = nil

            if JDHTML.isGIF(url) {
                // 1) 几十 KB 的静态帧先占位，避免大 GIF 下载期间空白。
                let placeholder = JDHTML.staticGIFURL(url) ?? url
                placeholderTask = fetch(placeholder) { [weak self] data in
                    guard let data, let image = Self.decode(data) else { return }
                    Task { @MainActor [weak self] in
                        // 动画已到位时不能再被静态占位覆盖。
                        guard let self, gen == self.generation, !self.animatedApplied,
                              let view = self.targetView else { return }
                        self.apply(image, into: view)
                    }
                }

                // 2) large/*.gif 是唯一带动画的版本；系统解码保留每帧真实延迟。
                guard let animated = JDHTML.animatedGIFURL(url) else {
                    markFailureIfNeeded(gen: gen)
                    return
                }
                if let cached = InlineImageCache.shared.image(for: animated) {
                    animatedApplied = true
                    apply(cached, into: view)
                    return
                }
                mainTask = fetch(animated) { [weak self] data in
                    guard let data, let image = Self.decode(data) else {
                        Task { @MainActor [weak self] in
                            self?.markFailureIfNeeded(gen: gen)
                        }
                        return
                    }
                    InlineImageCache.shared.store(image, dataCount: data.count, for: animated)
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation, let view = self.targetView else { return }
                        self.animatedApplied = true
                        self.apply(image, into: view)
                    }
                }
            } else {
                let target = JDHTML.displayURL(url, thumbnail: thumbnail)
                if let cached = InlineImageCache.shared.image(for: target) {
                    apply(cached, into: view)
                    return
                }
                mainTask = fetch(target) { [weak self] data in
                    guard let data, let image = Self.decode(data) else {
                        Task { @MainActor [weak self] in
                            self?.markFailureIfNeeded(gen: gen)
                        }
                        return
                    }
                    InlineImageCache.shared.store(image, dataCount: data.count, for: target)
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation, let view = self.targetView else { return }
                        self.apply(image, into: view)
                    }
                }
            }
        }

        /// iOS 26 上 `UIImage(data:)` 对 GIF 只返回首帧（实测 frames=0），
        /// 必须用 ImageIO 逐帧解码；总时长取各帧延迟之和，不再取平均值。
        nonisolated private static func decode(_ data: Data) -> UIImage? {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    return UIImage(data: data)
                }
                let count = CGImageSourceGetCount(source)
                guard count > 1 else { return UIImage(data: data) }

                var frames: [UIImage] = []
                var totalDelay: TimeInterval = 0
                for index in 0..<count {
                    guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                    frames.append(UIImage(cgImage: cg))
                    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                    totalDelay += max(delay, 0.02)
                }
                guard !frames.isEmpty else { return UIImage(data: data) }
                return UIImage.animatedImage(with: frames, duration: totalDelay)
            }
        }

        private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) -> URLSessionDataTask {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                guard error == nil, let data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    completion(nil)
                    return
                }
                completion(data)
            }
            task.resume()
            return task
        }

        private func apply(_ image: UIImage, into view: FittingImageView) {
            hasImage = true
            view.image = image
            loader.image = image
            loader.phase = .loaded
        }

        private func markFailureIfNeeded(gen: Int) {
            guard gen == generation, !hasImage else { return }
            loader.phase = .failed
        }
    }
}

/// UIImageView 自带 intrinsicContentSize：按可用宽度与图片比例给出高度，
/// 图片按原比例完整显示，整行自然变高，下面内容顺次下移。
final class FittingImageView: UIView {
    private let imageView = UIImageView()
    private var aspect: CGFloat = 0

    var image: UIImage? {
        didSet {
            let size = image?.size ?? .zero
            aspect = size.width > 0 ? size.height / size.width : 0
            imageView.image = image
            // 列表复用 / 从静态占位换成动画时，UIImageView 不总会自动起播。
            if (image?.images?.count ?? 0) > 1 { imageView.startAnimating() }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        if bounds.width > 0 { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32
        guard aspect > 0 else { return CGSize(width: width, height: 220) }
        return CGSize(width: UIView.noIntrinsicMetric, height: width * aspect)
    }
}
