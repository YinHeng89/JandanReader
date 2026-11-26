import SwiftUI
import UIKit

extension Notification.Name {
    /// 双击当前底部 Tab：object 为频道 id（String）；设置页双击不发。
    static let jdTabDoubleTap = Notification.Name("jdTabDoubleTap")
}

/// 拦截底部 Tab 点击：重复点当前 tab 时单击不做任何事（系统默认会 pop 到根），
/// 双击则发通知让列表置顶并刷新。切换其它 tab 保持系统默认行为。
///
/// 关键：**不能**替换 SwiftUI TabView 内部的 UITabBarController.delegate——
/// 它会破坏 SwiftUI 对各 tab 导航栈的管理，表现为「首页点文章跳到无聊图」。
/// 改为只在 UITabBar 上挂手势：重复点当前 tab 时吞掉触摸阻止 pop，其它 tab 不接管。
final class TabTapController: NSObject {
    private struct TapRecord {
        let index: Int
        let time: TimeInterval
    }

    private var lastTap: TapRecord?
    private var lastFired: TimeInterval = 0
    private weak var installedBar: UITabBar?

    /// 由外层提供当前选中的 tab 序号。不能依赖 UITabBar.selectedItem：
    /// iOS 18+ 的 SwiftUI TabView 不一定给 items/selectedItem 赋值。
    var currentTabIndex: (() -> Int)?

    /// 幂等安装；host VC 的布局回调会多次调用，避免重复加手势。
    func install(on bar: UITabBar) {
        guard installedBar !== bar else { return }
        installedBar = bar
        let tap = UITapGestureRecognizer(target: self, action: #selector(tabBarTapped(_:)))
        tap.cancelsTouchesInView = true
        tap.delegate = self
        bar.addGestureRecognizer(tap)
    }

    private func index(of point: CGPoint, in bar: UITabBar) -> Int? {
        // UITabBarButton 是系统私有视图，用 accessibilityTraits 识别，不直接引用私有类。
        let buttons = bar.subviews
            .filter { $0.accessibilityTraits.contains(.button) && $0.frame.width > 20 }
            .sorted { $0.frame.minX < $1.frame.minX }
        // SwiftUI TabView 的 items 可能为空；按钮数量才是可靠的 tab 数。
        let count = max(buttons.count, bar.items?.count ?? 0)
        guard count > 0 else { return nil }
        if let found = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            return found
        }
        // 识别不到按钮视图时按等宽分区兜底（4 个 tab 均分）。
        let index = Int(point.x / max(bar.bounds.width / CGFloat(count), 1))
        return (0..<count).contains(index) ? index : nil
    }

    @objc private func tabBarTapped(_ gesture: UITapGestureRecognizer) {
        guard let bar = gesture.view as? UITabBar,
              let idx = index(of: gesture.location(in: bar), in: bar) else { return }
        noteTap(idx)
    }

    /// 同一个 tab 在 0.8 秒内第二次触摸视为双击。
    private func noteTap(_ index: Int) {
        let now = Date().timeIntervalSince1970
        if let previous = lastTap, previous.index == index, now - previous.time < 0.8 {
            lastTap = nil
            guard now - lastFired > 0.6 else { return }
            lastFired = now
            if index < Channel.all.count {
                NotificationCenter.default.post(
                    name: .jdTabDoubleTap, object: Channel.all[index].id
                )
            }
        } else {
            lastTap = TapRecord(index: index, time: now)
        }
    }
}

extension TabTapController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let bar = gestureRecognizer.view as? UITabBar,
              let idx = index(of: touch.location(in: bar), in: bar),
              let selectedIndex = currentTabIndex?() else { return false }
        // 只接管「重复点当前 tab」；切其它 tab 完全交给系统，避免打断导航栈管理。
        return idx == selectedIndex
    }
}

/// 把手势挂到 SwiftUI TabView 底层的 UITabBar 上（不碰 delegate）。
struct TabDelegateHost: UIViewControllerRepresentable {
    let controller: TabTapController

    func makeUIViewController(context: Context) -> TabDelegateHostVC {
        TabDelegateHostVC(controller: controller)
    }

    func updateUIViewController(_ uiViewController: TabDelegateHostVC, context: Context) {}
}

final class TabDelegateHostVC: UIViewController {
    let controller: TabTapController

    init(controller: TabTapController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attach()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attach()
    }

    private func attach() {
        guard let tabBarController else { return }
        controller.install(on: tabBarController.tabBar)
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

    /// 兜底：host VC 的 appear 时机在某些 iOS 版本上不稳定，从 keyWindow 再挂一次（幂等）。
    private static func attachTabTap(controller: TabTapController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        func findTabBar(in vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let tab = vc as? UITabBarController { return tab }
            for child in vc.children {
                if let tab = findTabBar(in: child) { return tab }
            }
            return nil
        }
        guard let tab = findTabBar(in: window?.rootViewController) else { return }
        controller.install(on: tab.tabBar)
    }

    var body: some View {
        tabView
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(settings.darkMode ? .dark : .light)
            .onAppear {
                guard !ui.didConfigure else { return }
                ui.didConfigure = true
                let state = ui
                ui.tabTap.currentTabIndex = { [weak state] in
                    guard let state else { return -1 }
                    switch state.selected {
                    case .channel(let channel):
                        return Channel.all.firstIndex(of: channel) ?? -1
                    case .settings:
                        return Channel.all.count
                    }
                }
                router.configure(
                    history: history,
                    openAccount: { ui.showAccount = true },
                    openExternally: { url in UIApplication.shared.open(url) }
                )
                router.switchChannel = { channel in ui.selected = .channel(channel) }
                // TabView 三个 tab 同时存在，先把各自的 store 建好。
                Channel.all.forEach { router.ensure($0) }
                ui.selected = .channel(Channel.withID(settings.lastChannelID))
                PrefsStore.shared.configure(settings: settings, banned: banned, auth: auth)
                // 登录态存在 Cookie 里，但 user 需要请求 /member/get_info 才能拿到。
                // 不在启动时 refresh 的话，重启后 auth.isLoggedIn 一直是 false。
                Task { await auth.refresh() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Self.attachTabTap(controller: ui.tabTap)
                }
            }
            .onChange(of: ui.selected) { _, newValue in
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

    // MARK: - Tabs（Apple 官方 TabView / Tab，iOS 26 自动液态玻璃）

    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    Tab(channel.title, systemImage: channel.symbol, value: AppTab.channel(channel)) {
                        navigationContent(for: channel)
                            .background(TabDelegateHost(controller: ui.tabTap).frame(width: 0, height: 0))
                    }
                }
                Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                    settingsTab
                        .background(TabDelegateHost(controller: ui.tabTap).frame(width: 0, height: 0))
                }
                .badge(notices.unread > 0 ? Text("\(notices.unread)") : nil)
            }
        } else {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    navigationContent(for: channel)
                        .background(TabDelegateHost(controller: ui.tabTap).frame(width: 0, height: 0))
                        .tabItem {
                            Label(channel.title, systemImage: channel.symbol)
                        }
                        .tag(AppTab.channel(channel))
                }
                    settingsTab
                        .background(TabDelegateHost(controller: ui.tabTap).frame(width: 0, height: 0))
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
        SettingsView(showsDoneButton: false)
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
                        destinationView(for: route)
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
    private func destinationView(for route: JDNavigation) -> some View {
        switch route {
        case .user(let id, let nickname):
            UserProfileView(userID: id, nickname: nickname)
                .environmentObject(settings)
                .environmentObject(banned)
                .environmentObject(router)
                .environmentObject(auth)
        default:
            PostDetailView(item: item(from: route))
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
