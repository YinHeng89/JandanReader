import SwiftUI
import UIKit

extension Notification.Name {
    /// 双击当前底部 Tab：object 为频道 id（String）；设置页双击不发。
    static let jdTabDoubleTap = Notification.Name("jdTabDoubleTap")
}

/// 双击当前底部 Tab：置顶 + 刷新。
///
/// 定论（多次返工）：
/// 1. 不能替换 SwiftUI TabView 内部的 UITabBarController.delegate——会串各 tab 导航栈。
/// 2. 不能依赖 UITabBar.items / selectedItem / 按钮子视图——iOS 18+ SwiftUI 下可能为空。
/// 3. UIGestureRecognizer 吞不掉 TabView 内部对「重复点当前 tab」的 pop-to-root，
///    所以单击仍会置顶。改用透明覆盖视图：当前 tab 位置吞掉触摸，其它 tab 位置放行。
final class TabTapController: NSObject {
    private struct TapRecord {
        let index: Int
        let time: TimeInterval
    }

    private var lastTap: TapRecord?
    private var lastFired: TimeInterval = 0
    private weak var installedOverlay: TabTapOverlay?

    /// 当前选中的 tab 序号，由外层提供。
    var currentTabIndex: (() -> Int)?
    /// tab 总数 = 频道数 + 设置页。
    var tabCount: Int = 0

    func install(on window: UIWindow) {
        if let overlay = installedOverlay {
            if overlay.window === window {
                window.bringSubviewToFront(overlay)
                return
            }
            overlay.removeFromSuperview()
        }
        let overlay = TabTapOverlay()
        overlay.backgroundColor = .clear
        overlay.controller = self
        overlay.frame = CGRect(x: 0, y: window.bounds.height - 96,
                               width: window.bounds.width, height: 96)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        window.addSubview(overlay)
        installedOverlay = overlay
    }

    /// tab bar 等宽分区，按 x 坐标算序号。
    func tabIndex(at point: CGPoint, in bounds: CGRect) -> Int? {
        guard tabCount > 0, bounds.width > 0 else { return nil }
        let each = bounds.width / CGFloat(tabCount)
        let idx = Int(point.x / max(each, 1))
        return (0..<tabCount).contains(idx) ? idx : nil
    }

    /// 当前 tab 在 0.8 秒内第二次点击视为双击；0.6 秒内只发一次通知。
    fileprivate func noteTap(_ index: Int) {
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

/// 盖在底部 tab bar 上的透明视图：
/// - 点在当前 tab：hitTest 返回 self 吞掉触摸，系统收不到 → 单击无动作；双击发通知。
/// - 点在其它 tab：hitTest 返回 nil 穿透给系统 → 切 tab / 导航栈都正常。
final class TabTapOverlay: UIView {
    weak var controller: TabTapController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { superview?.bringSubviewToFront(self) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point),
              let controller,
              let idx = controller.tabIndex(at: point, in: bounds),
              let selected = controller.currentTabIndex?(),
              idx == selected else { return nil }
        return self
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let controller,
              let idx = controller.tabIndex(at: touch.location(in: self), in: bounds) else { return }
        controller.noteTap(idx)
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

    /// 直接挂到 keyWindow，不依赖 UITabBar 的内部结构。
    private static func attachTabTap(controller: TabTapController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        // isKeyWindow 在多 scene 时可能为 false，取不到就退回第一个 window（install 幂等）。
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        controller.install(on: window)
    }

    var body: some View {
        tabView
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(settings.darkMode ? .dark : .light)
            .onAppear {
                guard !ui.didConfigure else { return }
                ui.didConfigure = true
                let state = ui
                ui.tabTap.tabCount = Channel.all.count + 1
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
                // 每次切 tab 都再挂一次（幂等），兜住启动延迟挂载错过 keyWindow 的情况。
                Self.attachTabTap(controller: ui.tabTap)
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
