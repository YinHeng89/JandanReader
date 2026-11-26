import SwiftUI
import UIKit
import ImageIO
import AVFoundation

/// 图片流里的图片：按原比例完整显示（不裁剪）。
/// GIF 默认只显示静态缩略图并暂停，点击后才加载 mp4 循环播放。
struct InlineAnimatedImageView: View {
    let url: URL

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var loader = InlineImageLoader()

    private var isGIF: Bool { JDHTML.isGIF(url) }

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

            // GIF 未播放时叠一个「点击播放」标记，提示可点开动画。
            if isGIF && !loader.isPlaying {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label(loader.isLoadingAnimation ? "加载中" : "点击播放 GIF",
                              systemImage: loader.isLoadingAnimation ? "arrow.triangle.2.circlepath" : "play.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
                }
            }
        }
        // 高度交给 SwiftUI 的 aspectRatio 决定，而不是 UIView 的 intrinsicContentSize：
        // List 会缓存行高，UIView 异步改 intrinsic 不会触发行高重算，下一行会盖到图片上。
        // aspect 参数为 宽/高，loader.aspect 是 高/宽，故取倒数。
        .aspectRatio(loader.aspect > 0 ? 1 / loader.aspect : 1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            guard isGIF, !loader.isPlaying else { return }
            loader.requestPlay()
        }
    }
}

@MainActor
final class InlineImageLoader: ObservableObject {
    @Published var phase: InlineImagePhase = .loading
    @Published var image: UIImage?
    /// 用户是否已请求播放 GIF（点击触发）。
    @Published var playRequested = false
    /// 动画是否已在显示（mp4 或逐帧 GIF 已就位）。
    @Published var isPlaying = false
    @Published var isLoadingAnimation = false
    /// 当前图片的 高/宽，SwiftUI 用它算出确定高度，避免 List 行高缓存错位。
    @Published var aspect: CGFloat = 0

    func setAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = size.height / size.width
    }

    func requestPlay() {
        guard !playRequested else { return }
        playRequested = true
        isLoadingAnimation = true
    }

    func markPlaying() {
        isPlaying = true
        isLoadingAnimation = false
    }

    func markAnimationFailed() {
        isLoadingAnimation = false
    }

    func reset() {
        playRequested = false
        isPlaying = false
        isLoadingAnimation = false
    }
}

enum InlineImagePhase {
    case loading, loaded, failed
}

/// 解码后的图片缓存。成本按解码后的位图内存计算，而不是原始 data 大小。
final class InlineImageCache {
    static let shared = InlineImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 关键：一张 mw1024 图片的 JPEG 只有几百 KB，解码位图却要 4~6MB；
        // 动画 GIF 131 帧解码后可达 80MB，文件本身只有 7MB。
        // 旧实现按 data.count 计 cost，NSCache 以为没占内存就几乎不淘汰，
        // 快速滑动时解码图持续堆积 → 内存压缩 / Jetsam → 列表卡死。
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 60
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        // 解码位图约 4 字节/像素，动图再乘帧数，这是实际驻留内存的近似值。
        let frames = max(image.images?.count ?? 1, 1)
        let bytes = image.size.width * image.size.height * 4 * CGFloat(frames)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: max(Int(bytes), 1))
    }

    func clear() { cache.removeAllObjects() }
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
        // 用户点击 GIF 后开始加载并播放动画。
        if loader.playRequested && !context.coordinator.playbackStarted {
            context.coordinator.play(url, into: uiView)
        }
    }

    static func dismantleUIView(_ uiView: FittingImageView, coordinator: Coordinator) {
        coordinator.cancelAll()
        uiView.stopVideo()
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private let loader: InlineImageLoader
        private weak var targetView: FittingImageView?
        private var placeholderTask: URLSessionDataTask?
        private var mainTask: URLSessionDataTask?
        private var probeTask: URLSessionDataTask?
        private var currentKey: String?
        private var generation = 0
        private var hasImage = false
        private var animatedApplied = false
        /// 是否已为该图片启动过动画（点击后只启动一次）。
        private(set) var playbackStarted = false

        /// mp4 可用性缓存：img.toto.im 有 mp4，img.jandan.net 等老 CDN 没有。
        private static let availabilityLock = NSLock()
        private static var videoAvailability: [String: Bool] = [:]

        init(loader: InlineImageLoader) { self.loader = loader }

        func cancelAll() {
            placeholderTask?.cancel()
            mainTask?.cancel()
            probeTask?.cancel()
            placeholderTask = nil
            mainTask = nil
            probeTask = nil
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
            playbackStarted = false
            loader.reset()
            loader.aspect = 0
            loader.image = nil
            loader.phase = .loading
            view.image = nil
            view.onSizeChange = nil
            view.stopVideo()

            if JDHTML.isGIF(url) {
                // GIF 默认只加载几十 KB 的静态帧，不下载 mp4、不自动播放。
                // 点击后由 play() 负责加载动画。
                let placeholder = JDHTML.staticGIFURL(url) ?? url
                placeholderTask = fetch(placeholder) { [weak self] data in
                    guard let data, let image = Self.decode(data) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation, !self.animatedApplied,
                              let view = self.targetView else { return }
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
                    InlineImageCache.shared.store(image, for: target)
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation, let view = self.targetView else { return }
                        self.apply(image, into: view)
                    }
                }
            }
        }

        /// 用户点击 GIF 后才调用：探测同名 mp4 并播放，失败回退逐帧 GIF。
        func play(_ url: URL, into view: FittingImageView) {
            guard !playbackStarted, JDHTML.isGIF(url) else { return }
            playbackStarted = true
            let gen = generation
            animatedApplied = false

            // 站点前端实际用同名 mp4 播放 GIF：H.264 硬件解码、边下边播。
            if let video = JDHTML.animatedVideoURL(url) {
                let key = video.absoluteString
                Self.availabilityLock.lock()
                let known = Self.videoAvailability[key]
                Self.availabilityLock.unlock()
                if known == true {
                    applyVideo(video, gen: gen, into: view)
                    return
                }
                if known == false {
                    loadAnimatedGIF(url, gen: gen, into: view)
                    return
                }
                probeTask = probe(video) { [weak self] available in
                    Self.availabilityLock.lock()
                    Self.videoAvailability[key] = available
                    Self.availabilityLock.unlock()
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation, let view = self.targetView else { return }
                        if available {
                            self.applyVideo(video, gen: gen, into: view)
                        } else {
                            self.loadAnimatedGIF(url, gen: gen, into: view)
                        }
                    }
                }
            } else {
                loadAnimatedGIF(url, gen: gen, into: view)
            }
        }

        /// 老 CDN 没有 mp4，先用一个字节的范围请求探测，再决定播放方式。
        nonisolated private func probe(_ url: URL, completion: @escaping (Bool) -> Void) -> URLSessionDataTask {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.setValue(JDAPI.userAgent, forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    completion(false)
                    return
                }
                let type = http.allHeaderFields["Content-Type"] as? String ?? ""
                completion(type.localizedCaseInsensitiveContains("video"))
            }
            task.resume()
            return task
        }

        /// 兜底：老 CDN 无 mp4 时的逐帧解码。iOS 26 上 UIImage(data:) 只解首帧，
        /// 必须用 ImageIO 逐帧解码；总时长取各帧延迟之和，不再取平均值。
        private func loadAnimatedGIF(_ url: URL, gen: Int, into view: FittingImageView) {
            guard let animated = JDHTML.animatedGIFURL(url) else {
                Task { @MainActor [weak self] in self?.markFailureIfNeeded(gen: gen) }
                return
            }
            if let cached = InlineImageCache.shared.image(for: animated) {
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation, let view = self.targetView else { return }
                    self.animatedApplied = true
                    self.apply(cached, into: view)
                    self.loader.markPlaying()
                }
                return
            }
            mainTask = fetch(animated) { [weak self] data in
                guard let data, let image = Self.decode(data) else {
                    Task { @MainActor [weak self] in self?.loader.markAnimationFailed() }
                    return
                }
                InlineImageCache.shared.store(image, for: animated)
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation, let view = self.targetView else { return }
                    self.animatedApplied = true
                    self.apply(image, into: view)
                    self.loader.markPlaying()
                }
            }
        }

        @MainActor
        private func applyVideo(_ video: URL, gen: Int, into view: FittingImageView) {
            guard gen == generation else { return }
            animatedApplied = true
            hasImage = true
            view.onSizeChange = { [weak self] size in
                Task { @MainActor [weak self] in self?.loader.setAspect(size) }
            }
            view.playVideo(video)
            loader.phase = .loaded
            loader.markPlaying()
        }

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

        nonisolated private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) -> URLSessionDataTask {
            var request = URLRequest(url: url)
            request.setValue(JDAPI.userAgent, forHTTPHeaderField: "User-Agent")
            // 走统一缓存 session：命中磁盘/内存时直接返回，滚动回看不重复下载。
            let task = ImageCache.session.dataTask(with: request) { data, response, error in
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
            loader.setAspect(image.size)
            loader.phase = .loaded
        }

        private func markFailureIfNeeded(gen: Int) {
            guard gen == generation, !hasImage else { return }
            loader.phase = .failed
        }
    }
}

/// 图片按原比例完整显示；GIF 的 mp4 叠在同一比例上静音循环播放。
/// 高度完全由外层 SwiftUI `.aspectRatio` 决定，UIView 不再参与 intrinsic 计算，
/// 避免滑动时 invalidateIntrinsicContentSize 触发 Auto Layout 反馈循环。
final class FittingImageView: UIView {
    private let imageView = UIImageView()
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?
    private var sizeObservation: NSKeyValueObservation?
    /// 视频真实尺寸到位后通知外层更新 SwiftUI 布局高度。
    var onSizeChange: ((CGSize) -> Void)?

    var image: UIImage? {
        didSet {
            stopVideo()
            imageView.image = image
            // 列表复用 / 从静态占位换成动画时，UIImageView 不总会自动起播。
            if (image?.images?.count ?? 0) > 1 { imageView.startAnimating() }
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

    deinit { stopVideo() }

    /// 用 AVPlayer 播放站点同款 mp4；静音、循环、边下边播，不再逐帧解码大 GIF。
    func playVideo(_ url: URL) {
        stopVideo()
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer.addSublayer(layer)
        self.player = player
        self.playerLayer = layer

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        // 视频真实尺寸到位后修正比例，避免高度按默认 220 显示。
        sizeObservation = player.currentItem?.observe(\.presentationSize, options: [.initial, .new]) {
            [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            // 高度由 SwiftUI 的 aspectRatio 控制，这里只通知尺寸变化。
            Task { @MainActor [weak self] in
                self?.onSizeChange?(size)
            }
        }
        player.play()
    }

    func stopVideo() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObserver = nil
        sizeObservation = nil
        // 不能在这里清回调：applyVideo 先设置 onSizeChange 再调 playVideo，
        // playVideo 内部的 stopVideo 会把刚设置的回调清掉，视频比例永远修正不了。
        // 回调生命周期由 load() / dismantleUIView 负责。
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        playerLayer?.frame = bounds
    }
}
