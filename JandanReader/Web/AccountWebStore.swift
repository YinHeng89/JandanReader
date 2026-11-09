import Foundation
import WebKit
import UIKit

/// 用户中心独立页专用：独立的 WKWebView，共享默认 WKWebsiteDataStore（登录态互通）。
/// 不注入 cleanCSS —— 用户中心是 JS 渲染的 SPA，首页那套 DOM 清理规则不适用。
@MainActor
final class AccountWebStore: NSObject, ObservableObject {

    let webView: WKWebView
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var errorMessage: String?

    /// 用户中心里点到内容链接时，交给外壳关闭本页并回主频道打开。
    var onOpenContent: ((URL) -> Void)?

    init(url: URL, darkMode: Bool) {
        let controller = WKUserContentController()
        // 用独立页的精简清理规则：去掉站点导航/页脚/面包屑，保留 SPA 自身排版。
        controller.addUserScript(WKUserScript(
            source: PageScripts.bootstrap(
                dark: darkMode,
                clean: true,
                fontPercent: 100,
                css: PageScripts.accountCSS
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsBackForwardNavigationGestures = true

        self.webView = view
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: url))
    }

    func reload() {
        errorMessage = nil
        webView.reload()
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }

    private func syncBackState() { canGoBack = webView.canGoBack }

    private func blockedAd(_ host: String) -> Bool {
        let blocked = [
            "doubleclick.net", "googlesyndication.com", "google-analytics.com",
            "googletagmanager.com", "adsrvr.org", "adnxs.com", "criteo.com",
        ]
        return blocked.contains { host.hasSuffix($0) }
    }
}

// MARK: - WKNavigationDelegate

extension AccountWebStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        syncBackState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncBackState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let host = url.host ?? ""
        guard !blockedAd(host) else {
            decisionHandler(.cancel)
            return
        }

        // target="_blank" 在本页打开。
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: url))
            return
        }

        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        let userClicked = navigationAction.navigationType == .linkActivated

        // 用户中心内部的功能页跳转（消息、会员...）留在本页。
        if userClicked, AccountRoute.isAccount(url) {
            decisionHandler(.allow)
            return
        }

        // 内容链接（文章、频道等）：关页，回主频道打开，保证频道条焦点正确。
        if userClicked, host.hasSuffix("jandan.net") {
            decisionHandler(.cancel)
            onOpenContent?(url)
            return
        }

        // 站外链接交给系统浏览器。
        if userClicked, url.scheme?.hasPrefix("http") == true {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
            return
        }

        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension AccountWebStore: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if !blockedAd(url.host ?? "") {
            if url.host?.hasSuffix("jandan.net") == true {
                webView.load(URLRequest(url: url))
            } else if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }
}
