import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let store: WebStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // WKWebView 由 WebRouter 强持有，这里只从当前视图树摘下，不销毁。
    }
}
