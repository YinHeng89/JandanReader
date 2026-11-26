import SwiftUI
import WebKit

/// 微信扫码登录：站点走标准网站应用扫码（snsapi_login，AppID wxf9e33c4e898a8473）。
/// 在 App 内用 WKWebView 打开二维码页，扫码授权成功后服务端 callback 下发登录 Cookie，
/// 再把 WKWebView 的 Cookie 同步到 URLSession 共享存储，即可完成登录态。
struct WeChatLoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var web = WeChatWebState()

    /// 授权完成后服务端 302 回的地址；用站内首页，登录后自然回到内容流。
    private let returnURL = "https://jandan.net/"

    var body: some View {
        NavigationStack {
            ZStack {
                WeChatWebView(state: web, returnURL: returnURL)

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
            guard succeeded else { return }
            Task {
                // WKWebView 的 Cookie 是独立存储，必须同步给 URLSession.shared 才能带上登录态。
                await WeChatCookieSync.syncFromWebView()
                await auth.refresh(force: true)
                await MainActor.run { dismiss() }
            }
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

    func markLoading() {
        isLoading = true
        message = nil
    }

    func fail(_ message: String) {
        self.message = message
        isLoading = false
    }

    func reload() {
        reloadToken += 1
        isLoading = true
        message = nil
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

    func makeCoordinator() -> Coordinator { Coordinator(state: state, returnURL: returnURL) }

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
        private let returnURL: String
        var lastReloadToken = 0
        private var sawCallback = false

        init(state: WeChatWebState, returnURL: String) {
            self.state = state
            self.returnURL = returnURL
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.markLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            let path = url.path
            // callback 是授权兑换阶段，完成后服务端 302 回 returnURL。
            if path.contains("/api/member/wechat/callback") {
                sawCallback = true
                return
            }
            if sawCallback, url.absoluteString.hasPrefix(returnURL) {
                state.isLoading = false
                state.loginSucceeded = true
            } else if path == "/" || path.contains("/member") {
                // 落回站内但未走 callback：可能是取消或失败，给出明确提示。
                state.fail("微信授权未完成，请重试")
            } else {
                // 停在微信二维码页，属于正常等待用户扫码。
                state.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.fail("加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 只允许站内与微信授权域名，避免跳到无关页面。
            guard let url = navigationAction.request.url,
                  let host = url.host,
                  host == "jandan.net" || host.hasSuffix(".weixin.qq.com") || host == "weixin.qq.com" else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
