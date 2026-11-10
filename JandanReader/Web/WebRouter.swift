import Foundation
import Combine

/// 每个频道懒加载一个 WKWebView，切回来时保留滚动位置与浏览栈。
@MainActor
final class WebRouter: ObservableObject {

    private(set) var stores: [String: WebStore] = [:]
    private var settings: AppSettings?
    private var history: HistoryStore?
    private var externalHandler: ((URL) -> Void)?
    private var accountHandler: ((URL) -> Void)?

    func configure(
        settings: AppSettings,
        history: HistoryStore,
        openExternally: @escaping (URL) -> Void,
        openAccount: @escaping (URL) -> Void
    ) {
        self.settings = settings
        self.history = history
        self.externalHandler = openExternally
        self.accountHandler = openAccount
    }

    func ensure(_ channel: Channel) {
        guard stores[channel.id] == nil, let settings, let history else { return }
        let store = WebStore(channel: channel, settings: settings, history: history)
        store.openExternally = externalHandler
        store.openAccount = accountHandler
        stores[channel.id] = store
        objectWillChange.send()
    }

    func store(for channel: Channel) -> WebStore? { stores[channel.id] }

    func applySettings() {
        stores.values.forEach { $0.applySettings() }
    }

    /// 所有「从原生侧打开 URL」的入口（设置页、阅读历史、顶栏、功能页回传）
    /// 统一走这里：功能页一律交给外壳独立呈现，不落回频道 WebView。
    /// 判定只放这一处，避免各入口各写一套导致设置页这类后门漏掉。
    func open(_ url: URL, in channel: Channel) {
        if AccountRoute.isAccount(url) {
            accountHandler?(url)
            return
        }
        ensure(channel)
        stores[channel.id]?.load(url)
    }
}
