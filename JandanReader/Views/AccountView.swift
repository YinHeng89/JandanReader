import SwiftUI
import WebKit

/// 用户中心独立全屏页：原生顶栏 + 独立 WKWebView，不显示频道条。
/// 这样频道条的选中态始终对应主频道内容，不会出现「焦点停在旧菜单」的错位。
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: AccountWebStore

    private let darkMode: Bool
    private let onOpenContent: (URL) -> Void

    init(url: URL, darkMode: Bool, onOpenContent: @escaping (URL) -> Void) {
        self.darkMode = darkMode
        self.onOpenContent = onOpenContent
        _store = StateObject(wrappedValue: AccountWebStore(url: url))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                AccountWebView(webView: store.webView)

                if store.isLoading {
                    ProgressView()
                        .tint(Color.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground).opacity(0.3))
                        .allowsHitTesting(false)
                }

                if let message = store.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                        Text("页面加载失败")
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("重试") { store.reload() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentColor)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(32)
                }
            }
            .navigationTitle(store.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        Button { store.goBack() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!store.canGoBack)
                        Button { store.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(darkMode ? .dark : .light)
        .onAppear { store.onOpenContent = onOpenContent }
    }
}

/// 本页生命周期内 webView 不会更换，因此不需要 updateUIView 换挂逻辑。
private struct AccountWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
