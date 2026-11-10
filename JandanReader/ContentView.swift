import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: WebRouter

    @StateObject private var ui = ContentViewState()

    private var store: WebStore? { router.store(for: ui.selected) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ChannelBar(selected: ui.selected, onSelect: selectChannel)
            ProgressLine(progress: store?.progress ?? 0, isLoading: store?.isLoading ?? false)

            webContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) { bottomToolbar }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(settings.darkMode ? .dark : .light)
        .onAppear {
            guard !ui.didConfigure else { return }
            ui.didConfigure = true
            router.configure(
                settings: settings,
                history: history,
                openExternally: { url in UIApplication.shared.open(url) },
                openAccount: { url in ui.accountURL = url }
            )
            let initial = Channel.withID(settings.lastChannelID)
            // 先建好 store 再改选中态，避免 body 先读到 nil。
            router.ensure(initial)
            ui.selected = initial
        }
        .onChange(of: ui.selected) { _, newValue in
            settings.lastChannelID = newValue.id
            // 兜底：从历史/外部跳转恢复时确保 store 存在；常规点击已在 selectChannel 建好。
            router.ensure(newValue)
        }
        .onChange(of: settings.darkMode) { _, _ in
            router.applySettings()
            // DOM 改了不代表手势返回的位图快照改了：标记过期（过渡遮罩生效），
            // 再让当前页以新主题重绘一次，刷新缓存快照。
            router.markThemeStale()
            router.reloadVisible(ui.selected)
        }
        .onChange(of: settings.cleanMode) { _, _ in router.applySettings() }
        .onChange(of: settings.fontScale) { _, _ in router.applySettings() }
        .sheet(isPresented: $ui.showSettings) {
            SettingsView { url in
                router.open(url, in: ui.selected)
            }
            .environmentObject(settings)
            .environmentObject(history)
        }
        .sheet(isPresented: $ui.showHistory) {
            HistoryView { url in
                router.open(url, in: ui.selected)
            }
            .environmentObject(history)
        }
        .sheet(isPresented: $ui.showShare) {
            ActivityView(url: store?.shareURL ?? Channel.home.url)
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: Binding(
            get: { ui.accountURL != nil },
            set: { shown in if !shown { ui.accountURL = nil } }
        )) {
            AccountView(
                url: ui.accountURL ?? AccountRoute.memberURL,
                darkMode: settings.darkMode
            ) { target in
                ui.accountURL = nil
                // 点到的若是频道首页，直接切频道，保证焦点与内容一致。
                if target.host?.hasSuffix("jandan.net") == true,
                   let channel = Channel.all.first(where: { $0.path == target.path }) {
                    selectChannel(channel)
                } else {
                    router.open(target, in: ui.selected)
                }
            }
        }
    }

    /// 频道切换的唯一入口：在用户事件上下文里先创建 store，再改选中态。
    /// 顺序反过来会让 body 先读到 nil，随后在 SwiftUI 视图更新事务内发布
    /// objectWillChange，iOS 26 上这次刷新会被丢弃，表现为「点了没反应」。
    private func selectChannel(_ channel: Channel) {
        router.ensure(channel)
        guard channel != ui.selected else {
            // 再点当前频道：网页内登录、点进文章后 URL 会漂走，
            // 用户点同一个标签期望回到该频道首页；重新加载会自动带上登录态 Cookie。
            router.store(for: channel)?.loadChannel()
            return
        }
        ui.selected = channel
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("煎蛋")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("地球上没有新鲜事")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 纯净模式隐藏了站点导航，用户中心必须有稳定的原生入口。
            // 与其它入口一样走 router.open，由 WebRouter 统一判定功能页。
            Button { router.open(AccountRoute.memberURL, in: ui.selected) } label: {
                IconButton(systemName: "person.crop.circle")
            }
            .buttonStyle(.plain)
            Button { ui.showHistory = true } label: {
                IconButton(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            Button { settings.darkMode.toggle() } label: {
                IconButton(systemName: settings.darkMode ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.plain)
            Button { ui.showSettings = true } label: {
                IconButton(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
    }

    // MARK: - Web area

    @ViewBuilder
    private var webContent: some View {
        ZStack {
            Color(.systemBackground)

            if let store {
                WebViewContainer(store: store)

                if let message = store.errorMessage {
                    errorCard(message: message) { store.reload() }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Color.accentColor)
                    Text("正在打开 \(ui.selected.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }

    private func errorCard(message: String, retry: @escaping () -> Void) -> some View {
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
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).opacity(0.75))
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                ToolButton(systemName: "chevron.left", enabled: store?.canGoBack ?? false) {
                    store?.goBack()
                }
                ToolButton(systemName: "chevron.right", enabled: store?.canGoForward ?? false) {
                    store?.goForward()
                }
                ToolButton(systemName: "arrow.clockwise") {
                    store?.reload()
                }
                ToolButton(systemName: "house") {
                    store?.loadChannel()
                }
                ToolButton(systemName: "square.and.arrow.up") {
                    ui.showShare = true
                }
                ToolButton(systemName: "safari") {
                    if let url = store?.shareURL { UIApplication.shared.open(url) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .background(.regularMaterial)
    }
}
