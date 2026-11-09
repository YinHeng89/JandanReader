import Foundation
import WebKit
import SwiftUI

@MainActor
final class WebStore: NSObject, ObservableObject {

    let channel: Channel
    let webView: WKWebView

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle: String
    @Published private(set) var errorMessage: String?

    private weak var settings: AppSettings?
    private weak var history: HistoryStore?
    private var observations: [NSKeyValueObservation] = []

    var openExternally: ((URL) -> Void)?

    init(channel: Channel, settings: AppSettings, history: HistoryStore) {
        self.channel = channel
        self.settings = settings
        self.history = history
        self.pageTitle = channel.title

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: PageScripts.bootstrap(
                dark: settings.darkMode,
                clean: settings.cleanMode,
                fontPercent: settings.fontSizePercent
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.alwaysBounceVertical = true
        view.scrollView.contentInsetAdjustmentBehavior = .automatic

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(named: "AccentColor") ?? .systemOrange
        view.scrollView.refreshControl = refresh

        self.webView = view
        super.init()

        refresh.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        view.navigationDelegate = self
        view.uiDelegate = self

        bindKVO(view)
        load(channel.url)
    }

    private func bindKVO(_ view: WKWebView) {
        let progress = view.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let value = webView.estimatedProgress
            Task { @MainActor in self?.progress = value }
        }
        let title = view.observe(\.title, options: [.new]) { [weak self] webView, _ in
            let value = webView.title
            Task { @MainActor in
                guard let value, !value.isEmpty else { return }
                self?.pageTitle = value
            }
        }
        observations = [progress, title]
    }

    // MARK: - Actions

    func load(_ url: URL) {
        errorMessage = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadRevalidatingCacheData
        webView.load(request)
    }

    func loadChannel() { load(channel.url) }

    func reload() {
        errorMessage = nil
        webView.reload()
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    @objc private func pulledToRefresh() {
        errorMessage = nil
        webView.reload()
    }

    var shareURL: URL { currentURL ?? channel.url }

    func applySettings() {
        guard let settings else { return }
        evaluate(PageScripts.setDark(settings.darkMode))
        evaluate(PageScripts.setClean(settings.cleanMode))
        evaluate(PageScripts.setFont(settings.fontSizePercent))
        evaluate(PageScripts.hideDuplicateTitle())
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: { _, _ in })
    }

    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }
}

// MARK: - WKNavigationDelegate

extension WebStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 0
        webView.scrollView.refreshControl?.endRefreshing()
        pageTitle = webView.title?.isEmpty == false ? (webView.title ?? channel.title) : channel.title
        refreshNavigationState()
        history?.record(title: webView.title, url: webView.url)
        applySettings()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        progress = 0
        webView.scrollView.refreshControl?.endRefreshing()
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        progress = 0
        webView.scrollView.refreshControl?.endRefreshing()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
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

        // 广告域名的自动跳转（含 iframe）既不加载、也不弹系统浏览器。
        guard !isAdHost(host) else {
            decisionHandler(.cancel)
            return
        }

        // target="_blank" 在 WKWebView 里默认无响应，改为当前页打开。
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            load(url)
            return
        }

        // 子框架导航不是用户主动跳转，放行即可。
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        // 仅用户主动点击的站外链接才交给系统浏览器。
        if navigationAction.navigationType == .linkActivated,
           !host.hasSuffix("jandan.net"),
           url.scheme?.hasPrefix("http") == true {
            decisionHandler(.cancel)
            openExternally?(url)
            return
        }

        decisionHandler(.allow)
    }

    private func isAdHost(_ host: String) -> Bool {
        let blocked = [
            "doubleclick.net",
            "googlesyndication.com",
            "google-analytics.com",
            "googletagmanager.com",
            "googlesyndication.com",
            "adsrvr.org",
            "adnxs.com",
            "criteo.com",
        ]
        return blocked.contains { host.hasSuffix($0) }
    }
}

// MARK: - WKUIDelegate

extension WebStore: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isAdHost(url.host ?? "") {
            if url.host?.hasSuffix("jandan.net") == true {
                load(url)
            } else if navigationAction.navigationType == .linkActivated {
                openExternally?(url)
            }
        }
        return nil
    }
}

// MARK: - Cache

enum WebCache {
    static func clear() async {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeSessionStorage,
        ]
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))
    }
}
