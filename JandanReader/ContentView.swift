import SwiftUI
import UIKit

extension Notification.Name {
    /// 双击当前底部 Tab：object 为频道 id（String）；设置页双击不发。
    static let jdTabDoubleTap = Notification.Name("jdTabDoubleTap")
}

/// 拦截底部 Tab 点击：重复点当前 tab 时单击不做任何事（系统默认会 pop 到根），
/// 双击则发通知让列表置顶并刷新。切换其它 tab 保持系统默认行为。
///
/// iOS 18+ 的 SwiftUI TabView 重复点当前 tab 时不一定调用 UIKit 的 shouldSelect，
/// 所以同时在 UITabBar 上挂一个不吞触摸的 tap 手势，直接按点击位置识别 tab。
final class TabTapController: NSObject, UITabBarControllerDelegate {
    private struct TapRecord {
        let index: Int
        let time: TimeInterval
    }

    private var records: [String: TapRecord] = [:]
    private var lastFired: TimeInterval = 0
    private weak var installedBar: UITabBar?

    func tabBarController(_ tabBarController: UITabBarController,
                          shouldSelect viewController: UIViewController) -> Bool {
        guard let vcs = tabBarController.viewControllers,
              let idx = vcs.firstIndex(of: viewController) else { return true }
        if tabBarController.selectedViewController === viewController {
            noteTap(idx, source: "delegate")
            return false
        }
        records.removeAll()
        return true
    }

    /// 幂等安装；host VC 的布局回调会多次调用，避免重复加手势。
    func install(on bar: UITabBar) {
        guard installedBar !== bar else { return }
        installedBar = bar
        let tap = UITapGestureRecognizer(target: self, action: #selector(tabBarTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        bar.addGestureRecognizer(tap)
    }

    @objc private func tabBarTapped(_ gesture: UITapGestureRecognizer) {
        guard let bar = gesture.view as? UITabBar,
              let count = bar.items?.count, count > 0 else { return }
        let point = gesture.location(in: bar)
        // UITabBarButton 是系统私有视图，用 accessibilityTraits 识别，不直接引用私有类。
        let buttons = bar.subviews
            .filter { $0.accessibilityTraits.contains(.button) && $0.frame.width > 20 }
            .sorted { $0.frame.minX < $1.frame.minX }
        let index: Int
        if let found = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            index = found
        } else {
            // 识别不到按钮视图时按等宽分区兜底（4 个 tab 均分）。
            index = Int(point.x / max(bar.bounds.width / CGFloat(count), 1))
        }
        guard (0..<count).contains(index) else { return }
        noteTap(index, source: "gesture")
    }

    /// 同一个 tab 在 0.8 秒内第二次触摸视为双击；不同来源（delegate/手势）不会互相误判。
    private func noteTap(_ index: Int, source: String) {
        let now = Date().timeIntervalSince1970
        if let previous = records[source], previous.index == index, now - previous.time < 0.8 {
            records[source] = nil
            // 两个来源可能同时上报同一次双击，限制 0.6 秒内只发一次。
            guard now - lastFired > 0.6 else { return }
            lastFired = now
            if index < Channel.all.count {
                NotificationCenter.default.post(
                    name: .jdTabDoubleTap, object: Channel.all[index].id
                )
            }
        } else {
            records[source] = TapRecord(index: index, time: now)
        }
    }
}

extension TabTapController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 不能吞掉 UITabBar 自己的触摸，否则 tab 切换会失效。
        true
    }
}

/// 把上面的 delegate / 手势挂到 SwiftUI TabView 底层的 UITabBarController 上。
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
        tabBarController.delegate = controller
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
        tab.delegate = controller
        controller.install(on: tab.tabBar)
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
