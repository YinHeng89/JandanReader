import SwiftUI
import UIKit
import ImageIO

/// 图片流里的图片：按原比例完整显示（不裁剪），GIF 逐帧循环播放。
struct InlineAnimatedImageView: View {
    let url: URL

    @StateObject private var loader = InlineImageLoader()

    var body: some View {
        ZStack {
            InlineImageContainer(url: url, loader: loader)

            if loader.phase == .loading {
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

/// 分享面板的内容。下载原图后给系统分享真实的图片数据，而不是一个链接。
@MainActor
final class ShareState: ObservableObject {
    @Published var item: Any?

    func prepareOriginal(from displayedURL: URL) async {
        let original = JDHTML.displayURL(displayedURL, thumbnail: false)
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
    @ObservedObject var loader: InlineImageLoader

    func makeCoordinator() -> Coordinator { Coordinator(loader: loader) }

    func makeUIView(context: Context) -> FittingImageView {
        let view = FittingImageView()
        context.coordinator.load(url, into: view)
        return view
    }

    func updateUIView(_ uiView: FittingImageView, context: Context) {}

    final class Coordinator {
        private let loader: InlineImageLoader
        private var task: URLSessionDataTask?

        init(loader: InlineImageLoader) { self.loader = loader }

        deinit { task?.cancel() }

        func load(_ url: URL, into view: FittingImageView) {
            task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let self, error == nil, let data else {
                    DispatchQueue.main.async { self?.loader.phase = .failed }
                    return
                }
                let image = Self.decode(data)
                DispatchQueue.main.async {
                    guard let image else {
                        self.loader.phase = .failed
                        return
                    }
                    view.image = image
                    self.loader.image = image
                    self.loader.phase = .loaded
                }
            }
            task?.resume()
        }

        /// GIF 逐帧解出并循环播放；单帧图按 UIImage 显示。
        static func decode(_ data: Data) -> UIImage? {
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
            return UIImage.animatedImage(with: frames, duration: totalDelay / TimeInterval(frames.count))
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
