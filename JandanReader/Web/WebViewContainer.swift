import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let store: WebStore

    func makeUIView(context: Context) -> WebHostView {
        let host = WebHostView()
        host.attach(store.webView)
        return host
    }

    func updateUIView(_ host: WebHostView, context: Context) {
        // 频道切换时 SwiftUI 复用同一个 representable，只会走 updateUIView。
        // 必须在这里换挂新频道的 WKWebView，否则画面一直停在启动时那个频道。
        host.attach(store.webView)
    }
}

/// 承载 WKWebView 的容器视图。
/// WKWebView 由 WebRouter 强持有，这里只负责换挂，切走时不销毁，
/// 因此各频道的滚动位置与浏览栈都能保留。
@MainActor
final class WebHostView: UIView {
    private weak var current: WKWebView?

    func attach(_ webView: WKWebView) {
        if current === webView, webView.superview === self { return }
        current?.removeFromSuperview()
        webView.removeFromSuperview()
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        addSubview(webView)
        current = webView
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        current?.frame = bounds
    }
}
