import SwiftUI
import WebKit

/// 微信扫码登录：站点走标准网站应用扫码（snsapi_login，AppID wxf9e33c4e898a8473）。
/// 在 App 内用 WKWebView 打开二维码页，扫码授权成功后服务端 callback 下发登录 Cookie，
/// 再把 WKWebView 的 Cookie 同步到 URLSession 共享存储，即可完成登录态。
///
/// 判定原则（审查 P0-2）：**不靠 didFinish 猜 URL**。
/// 302 中间跳转不会触发 didFinish，且初始二维码页 `/api/member/wechat/login`
/// 的 path 也含 `/member`，旧实现会把它误判成「授权未完成」。
/// 现在改为在导航策略 / 服务端重定向回调里观察整条链路，看到非 login 的
/// wechat 端点即标记 sawCallback，落到站内后再同步 Cookie 并用
/// `/api/member/get_info` 实测登录态，只有真的拿到 user 才算成功。
struct WeChatLoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var web = WeChatWebState()

    /// 授权完成后服务端 302 回的地址；用站内首页，登录后自然回到内容流。
    private let returnURL = "https://jandan.net/"

    var body: some View {
        NavigationStack {
            ZStack {
                WeChatWebView(state: web, returnURL: returnURL, auth: auth)

                if web.isLoading {
                    ProgressView().tint(Color.accentColor)
                }
                if let message = web.message {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28)).foregroundStyle(.orange)
                        Text(message).font(.caption).multilineTextAlignment(.center)
                        Button("重试") { web.reload() }
                            .buttonStyle(.borderedProminent).tint(Color.accentColor)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                }
            }
            .navigationTitle("微信登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onChange(of: web.loginSucceeded) { _, succeeded in
            // Cookie 同步与登录态校验已在 Coordinator 完成，这里只负责关闭页面。
            guard succeeded else { return }
            dismiss()
        }
    }
}

/// WebView 状态。Xcode 27 下用 ObservableObject 规避 View 内 @State 赋值限制。
@MainActor
final class WeChatWebState: ObservableObject {
    @Published var isLoading = true
    @Published var message: String?
    @Published var loginSucceeded = false
    private var reloadToken = 0

    var currentReloadToken: Int { reloadToken }

    func fail(_ message: String) {
        self.message = message
        isLoading = false
    }

    func reload() {
        reloadToken += 1
        isLoading = true
        message = nil
        loginSucceeded = false
    }
}

/// 把 WKWebView 里权威的 Cookie 同步到 App 的 URLSession 共享存储。
enum WeChatCookieSync {
    @MainActor
    static func syncFromWebView() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

struct WeChatWebView: UIViewRepresentable {
    @ObservedObject var state: WeChatWebState
    let returnURL: String
    let auth: AuthStore

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, auth: auth)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 微信 connect 页对移动端 UA 会引导去 App；用桌面 UA 保证出二维码。
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        load(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != state.currentReloadToken {
            context.coordinator.lastReloadToken = state.currentReloadToken
            context.coordinator.resetAuthorization()
            load(webView)
        }
    }

    private func load(_ webView: WKWebView) {
        guard let encoded = returnURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://jandan.net/api/member/wechat/login?return=\(encoded)") else { return }
        webView.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let state: WeChatWebState
        private let auth: AuthStore
        var lastReloadToken = 0
        private var sawCallback = false
        private var didVerify = false

        init(state: WeChatWebState, auth: AuthStore) {
            self.state = state
            self.auth = auth
        }

        func resetAuthorization() {
            sawCallback = false
            didVerify = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            guard let url = webView.url else { return }
            observe(url)
            // callback 页可能就是终点（不再 302），此时也要做一次登录态实测。
            if sawCallback { verifyLogin() }
            else if url.path.hasPrefix("/member/login") {
                state.fail("微信授权未完成，请重试")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.fail("加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            state.fail("加载失败：\(error.localizedDescription)")
        }

        /// 302 不会触发 didFinish，必须在重定向回调里也观察整条链路。
        func webView(_ webView: WKWebView,
                     didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url { observe(url) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 只放行站内 + 微信/QQ 资源域。res.wx.qq.com 等静态资源域名必须放行，
            // 否则二维码图片加载不出来。
            guard let url = navigationAction.request.url, isAllowed(url) else {
                decisionHandler(.cancel)
                return
            }
            observe(url)
            decisionHandler(.allow)
        }

        private func isAllowed(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host == "jandan.net" || host.hasSuffix(".jandan.net")
                || host == "qq.com" || host.hasSuffix(".qq.com")
                || host == "wechat.com" || host.hasSuffix(".wechat.com")
        }

        /// 只识别「wechat 端点」与「落回站内」，不再用宽泛的 path.contains("/member")。
        private func observe(_ url: URL) {
            guard let host = url.host?.lowercased(),
                  host == "jandan.net" || host.hasSuffix(".jandan.net") else { return }
            let path = url.path.lowercased()
            if path.contains("/api/member/wechat/") {
                if !path.hasSuffix("/login") { sawCallback = true }
                return
            }
            if sawCallback { verifyLogin() }
        }

        /// 唯一成功判据：同步 Cookie 后 /api/member/get_info 能拿到 user。
        private func verifyLogin() {
            guard !didVerify else { return }
            didVerify = true
            Task { @MainActor in
                // 给 WKWebView 一点时间把 302 的 Set-Cookie 落进 cookie store。
                try? await Task.sleep(for: .milliseconds(300))
                await WeChatCookieSync.syncFromWebView()
                await auth.refresh(force: true)
                if auth.isLoggedIn {
                    state.isLoading = false
                    state.message = nil
                    state.loginSucceeded = true
                } else {
                    state.fail("微信授权未生效，请重试或改用账号密码登录")
                }
            }
        }
    }
}
