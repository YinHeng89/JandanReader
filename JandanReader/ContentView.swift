import SwiftUI
import UIKit
import WebKit

/// 重复点击当前 Tab 时的「精确置顶」兜底——纯观察，不干预系统行为。
///
/// 系统 TabView 自带 pop-to-root + scroll-to-top，但实测只滚到小标题态的
/// -adjustedContentInset.top，不会恢复大标题展开态，第一条内容会被裁掉。
/// 这里只观察 tab bar 区域的点击：不改 delegate、不吞触摸、不改 selection，
/// 系统行为完全保留，仅在动画结束后补一次置顶并把大标题拉回展开态。
///
/// 与旧版的区别：点击区域用**真实 UITabBar 的 frame**，多下拉的距离由
/// **当前 UINavigationBar 高度**推导，目标 scrollView 排除 WKWebView 内部
/// 的嵌套视图；不再依赖 96 / 52 / 150 / 130 这组模拟器常数。
final class TabTopFix: NSObject, UIGestureRecognizerDelegate {
    var tabCount = 0
    var currentIndex: (() -> Int)?
    private weak var installedWindow: UIWindow?

    /// 幂等挂载：keyWindow 出现时机不固定，切 tab 时会再调一次。
    func install(on window: UIWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(windowTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func windowTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let window = gesture.view as? UIWindow,
              tabCount > 0,
              let selected = currentIndex?(),
              (0..<tabCount).contains(selected) else { return }
        let point = gesture.location(in: window)
        guard isInsideTabBar(point, in: window), selectedTabIndex(for: point, in: window) == selected else {
            return
        }
        // 等系统 pop-to-root / scroll-to-top 动画结束再补一次精确置顶。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak window] in
            guard let window else { return }
            Self.fixTop(in: window)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Tab bar 命中判定

    private func isInsideTabBar(_ point: CGPoint, in window: UIWindow) -> Bool {
        if let bar = Self.findTabBar(in: window) {
            let frame = bar.convert(bar.bounds, to: window)
            return point.y >= frame.minY - 8 && point.x >= frame.minX && point.x <= frame.maxX
        }
        // iOS 18+ 的 TabView 可能不用 UITabBar，退回到安全区 + 标准 tab bar 高度。
        return point.y >= window.bounds.height - window.safeAreaInsets.bottom - 49
    }

    private func selectedTabIndex(for point: CGPoint, in window: UIWindow) -> Int {
        if let bar = Self.findTabBar(in: window) {
            let frame = bar.convert(bar.bounds, to: window)
            let count = max(bar.items?.count ?? tabCount, 1)
            let each = frame.width / CGFloat(count)
            return Int((point.x - frame.minX) / max(each, 1))
        }
        let each = window.bounds.width / CGFloat(max(tabCount, 1))
        return Int(point.x / max(each, 1))
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar, !bar.isHidden { return bar }
        for sub in view.subviews {
            if let found = findTabBar(in: sub) { return found }
        }
        return nil
    }

    // MARK: - 精确置顶

    private static func fixTop(in window: UIWindow) {
        guard let scroll = bestScrollView(in: window) else { return }
        // 已经在顶部（含大标题展开态）就不再拉扯。
        guard scroll.contentOffset.y > -scroll.adjustedContentInset.top + 4 else { return }

        // 比 -inset.top 再多拉一个导航栏高度，触发系统重新展开大标题。
        // 展开后 inset.top 变大，系统会把 offset 一并带走，第二步再精确归位。
        let navHeight = findNavigationBar(in: window)?.frame.height ?? 0
        let extra = min(max(navHeight, 40), 80) // 小标题态导航栏高度，约 44~56
        scroll.setContentOffset(
            CGPoint(x: 0, y: -scroll.adjustedContentInset.top - extra), animated: false
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak scroll] in
            guard let scroll else { return }
            scroll.setContentOffset(
                CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false
            )
        }
    }

    /// 只挑当前主内容区的 scrollView：排除隐藏视图、横向小图墙、
    /// 以及 WKWebView 内部自带的那层（微信扫码页 / 内嵌网页不该被置顶）。
    private static func bestScrollView(in window: UIWindow) -> UIScrollView? {
        var best: UIScrollView?
        func walk(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scroll = view as? UIScrollView,
               scroll.window === window,
               scroll.isScrollEnabled,
               !isInsideWebView(scroll),
               scroll.bounds.width >= window.bounds.width * 0.8,
               scroll.bounds.height > 300,
               scroll.contentSize.height > scroll.bounds.height {
                if best == nil || scroll.bounds.height > best!.bounds.height { best = scroll }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return best
    }

    private static func isInsideWebView(_ view: UIView) -> Bool {
        var current: UIView? = view.superview
        while let node = current {
            if node is WKWebView { return true }
            current = node.superview
        }
        return false
    }

    private static func findNavigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar, !bar.isHidden { return bar }
        for sub in view.subviews {
            if let found = findNavigationBar(in: sub) { return found }
        }
        return nil
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var banned: BannedStore
    @ObservedObject private var notices = NoticeStore.shared

    @StateObject private var ui = ContentViewState()

    /// 设置页里打开收藏 / 历史时，内容应回到的频道。
    private var contentChannel: Channel {
        switch ui.selected {
        case .channel(let channel): return channel
        case .settings: return Channel.withID(settings.lastChannelID)
        }
    }

    var body: some View {
        tabView
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(settings.darkMode ? .dark : .light)
            .onAppear {
                guard !ui.didConfigure else { return }
                ui.didConfigure = true
                router.configure(
                    history: history,
                    openAccount: { ui.showAccount = true }
                )
                router.switchChannel = { channel in ui.selected = .channel(channel) }
                // TabView 三个 tab 同时存在，先把各自的 store 建好。
                Channel.all.forEach { router.ensure($0) }
                ui.selected = .channel(Channel.withID(settings.lastChannelID))
                PrefsStore.shared.configure(settings: settings, banned: banned, auth: auth)
                // 登录态存在 Cookie 里，但 user 需要请求 /member/get_info 才能拿到。
                // 不在启动时 refresh 的话，重启后 auth.isLoggedIn 一直是 false。
                Task { await auth.refresh() }
                configureTabTopFix()
            }
            .onChange(of: ui.selected) { _, newValue in
                // 每次切 tab 再挂一次（幂等），兜住启动时 window 尚未就绪的情况。
                Self.attachTabTopFix(controller: ui.tabTopFix)
                if case .channel(let channel) = newValue {
                    settings.lastChannelID = channel.id
                }
            }
            .onChange(of: auth.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    NoticeStore.shared.startPolling()
                    Task {
                        await NoticeStore.shared.refreshUnread()
                        await FavoriteStore.shared.refresh()
                        PrefsStore.shared.configure(settings: settings, banned: banned, auth: auth)
                        await PrefsStore.shared.pull()
                    }
                } else {
                    NoticeStore.shared.stopPolling()
                    NoticeStore.shared.reset()
                    FavoriteStore.shared.clear()
                }
            }
            .fullScreenCover(isPresented: $ui.showAccount) {
                AccountView()
                    .environmentObject(auth)
            }
    }

    private func configureTabTopFix() {
        ui.tabTopFix.tabCount = Channel.all.count + 1
        let state = ui
        ui.tabTopFix.currentIndex = { [weak state] in
            guard let state else { return -1 }
            switch state.selected {
            case .channel(let channel):
                return Channel.all.firstIndex(of: channel) ?? -1
            case .settings:
                return Channel.all.count
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak state] in
            guard let state else { return }
            Self.attachTabTopFix(controller: state.tabTopFix)
        }
    }

    /// keyWindow 在多 scene 下可能取不到，退回第一个 window；install 幂等。
    private static func attachTabTopFix(controller: TabTopFix) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var windows: [UIWindow] = []
        for scene in scenes { windows.append(contentsOf: scene.windows) }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        controller.install(on: window)
    }

    // MARK: - Tabs（Apple 官方 TabView / Tab，iOS 26 自动液态玻璃）

    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    Tab(channel.title, systemImage: channel.symbol, value: AppTab.channel(channel)) {
                        navigationContent(for: channel)
                    }
                }
                Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                    settingsTab
                }
                .badge(notices.unread > 0 ? Text("\(notices.unread)") : nil)
            }
        } else {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    navigationContent(for: channel)
                        .tabItem {
                            Label(channel.title, systemImage: channel.symbol)
                        }
                        .tag(AppTab.channel(channel))
                }
                    settingsTab
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .badge(notices.unread > 0 ? "\(notices.unread)" : nil)
                    .tag(AppTab.settings)
            }
        }
    }

    @ViewBuilder
    private var settingsTab: some View {
        SettingsView(showsDoneButton: false, contentChannel: contentChannel)
            .environmentObject(settings)
            .environmentObject(history)
            .environmentObject(router)
            .environmentObject(banned)
            .environmentObject(auth)
    }

    @ViewBuilder
    private func navigationContent(for channel: Channel) -> some View {
        if let store = router.store(for: channel) {
            NavigationStack(path: store.binding) {
                channelView(for: channel, store: store)
                    .environmentObject(settings)
                    .environmentObject(auth)
                    .navigationTitle(channel.title)
                    .navigationDestination(for: JDNavigation.self) { route in
                        destinationView(for: route, channel: channel)
                    }
            }
        } else {
            ProgressView().tint(Color.accentColor)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func channelView(for channel: Channel, store: FeedStore) -> some View {
        switch channel.id {
        case "pic", "beauty":
            PhotoFeedView(store: store).environmentObject(settings)
        default:
            HomeFeedView(store: store).environmentObject(settings)
        }
    }

    @ViewBuilder
    private func destinationView(for route: JDNavigation, channel: Channel) -> some View {
        switch route {
        case .user(let id, let nickname):
            UserProfileView(userID: id, nickname: nickname, channel: channel)
                .environmentObject(settings)
                .environmentObject(banned)
                .environmentObject(router)
                .environmentObject(auth)
        default:
            PostDetailView(item: item(from: route), channel: channel)
                .environmentObject(settings)
                .environmentObject(router)
                .environmentObject(banned)
                .environmentObject(auth)
        }
    }

    private func item(from route: JDNavigation) -> JDFeedItem {
        switch route {
        case .feed(let feed): return feed
        case .article(let id):
            return JDFeedItem(id: id, kind: .article, title: "", body: "", author: "", date: "",
                              imageURL: nil, commentCount: 0, positive: 0, negative: 0,
                              location: nil, avatar: nil)
        case .externalArticle(let id, let title, let kind):
            return JDFeedItem(id: id, kind: kind, title: title, body: "", author: "", date: "",
                              imageURL: nil, commentCount: 0, positive: 0, negative: 0,
                              location: nil, avatar: nil)
        case .user:
            // 用户页由 destinationView 单独处理，这里是不可达的兜底。
            return JDFeedItem(id: 0, kind: .article, title: "", body: "", author: "", date: "",
                              imageURL: nil, commentCount: 0, positive: 0, negative: 0,
                              location: nil, avatar: nil)
        }
    }
}
