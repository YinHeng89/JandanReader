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

    /// 当前承载本 WebView 的容器，用于 back-forward 过渡遮罩。weak 避免
    /// WebView → host → store 形成环；owningStore 校验避免复用时误盖。
    weak var host: WebHostView?
    private var backForwardPending = false
    private var hasCommitted = false
    private var pendingScrollOffset: CGPoint?

    /// 切主题后，WebKit 缓存的历史条目位图仍是旧主题。本页以新主题
    /// 重新渲染完成（didFinish）前都为 true，此期间返回过渡需要遮罩。
    private(set) var themeSnapshotStale = false

    /// 站外链接交给系统浏览器。
    var openExternally: ((URL) -> Void)?
    /// 用户中心 / 会员 / 消息等功能页交给外壳独立呈现。
    var openAccount: ((URL) -> Void)?

    init(channel: Channel, settings: AppSettings, history: HistoryStore) {
        self.channel = channel
        self.settings = settings
        self.history = history
        self.pageTitle = channel.title

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: PageScripts.bootstrap(
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

    private var activeHost: WebHostView? {
        guard let host, host.owningStore === self else { return nil }
        return host
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

    /// 切换主题时用：让当前页以新主题重新渲染，WebKit 才会在下次离开时
    /// 重新捕获历史条目的位图快照（旧的深色快照不会被更新）。
    /// 保留滚动位置，不丢浏览栈。
    func reloadPreservingOffset() {
        errorMessage = nil
        pendingScrollOffset = webView.scrollView.contentOffset
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
        activeHost?.darkMode = settings.darkMode
        evaluate(PageScripts.setDark(settings.darkMode))
        evaluate(PageScripts.setClean(settings.cleanMode))
        evaluate(PageScripts.setFont(settings.fontSizePercent))
        evaluate(PageScripts.hideDuplicateTitle())
    }

    // MARK: - Theme transition cover

    /// 切换主题时由 router 标记：缓存快照可能还是旧主题。
    func markThemeStale() { themeSnapshotStale = true }

    /// 只在快照确实可能过期时遮盖，正常浏览不会平白闪一层纯色。
    func beginThemeCover() {
        guard themeSnapshotStale else { return }
        activeHost?.showThemeCover(true)
    }

    func endThemeCover() { activeHost?.showThemeCover(false) }

    func scheduleThemeCoverRelease() {
        guard themeSnapshotStale else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            self.endThemeCover()
        }
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: { _, _ in })
    }

    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }

    private func finishLoading(_ webView: WKWebView) {
        isLoading = false
        progress = 0
        webView.scrollView.refreshControl?.endRefreshing()
        endThemeCover()
    }

    /// -999 = NSURLErrorCancelled：快速连点、policy cancel 后重新 load、
    /// 手势打断旧请求都会产生，属于正常流程，不是加载失败。
    private func shouldReport(_ error: Error, in webView: WKWebView) -> Bool {
        guard (error as NSError).code != NSURLErrorCancelled else { return false }
        // 本次导航已经成功 commit 出内容时，后续失败不该用全屏卡片盖住它。
        guard !hasCommitted || webView.url == nil else { return false }
        return true
    }
}

// MARK: - WKNavigationDelegate

extension WebStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        hasCommitted = false
        let covering = backForwardPending
        backForwardPending = false
        // 手势返回期间显示的是缓存位图，DOM 层同步改不到它，用主题色遮罩兜底。
        if covering { beginThemeCover() }
        evaluate(PageScripts.syncDark())
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommitted = true
        // bfcache 恢复不会重跑 atDocumentStart 脚本，文档提交后立刻纠正主题。
        evaluate(PageScripts.syncDark())
        endThemeCover()
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(webView)
        // 本页已用当前主题重绘，历史快照过期标记解除。
        themeSnapshotStale = false
        pageTitle = webView.title?.isEmpty == false ? (webView.title ?? channel.title) : channel.title
        refreshNavigationState()
        history?.record(title: webView.title, url: webView.url)
        applySettings()
        if let offset = pendingScrollOffset {
            pendingScrollOffset = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                webView.scrollView.setContentOffset(offset, animated: false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(webView)
        guard shouldReport(error, in: webView) else { return }
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(webView)
        guard shouldReport(error, in: webView) else { return }
        errorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .backForward { backForwardPending = true }

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

        // 用户中心 / 会员 / 消息等功能页不属于任何内容频道，交给外壳独立呈现，
        // 否则网页内容变了、频道条焦点还停在原频道。
        if AccountRoute.isAccount(url),
           navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            openAccount?(url)
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
            if AccountRoute.isAccount(url) {
                openAccount?(url)
            } else if url.host?.hasSuffix("jandan.net") == true {
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
