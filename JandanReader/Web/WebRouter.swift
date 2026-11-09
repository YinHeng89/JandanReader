import Foundation
import Combine

/// 每个频道懒加载一个 WKWebView，切回来时保留滚动位置与浏览栈。
@MainActor
final class WebRouter: ObservableObject {

    private(set) var stores: [String: WebStore] = [:]
    private var settings: AppSettings?
    private var history: HistoryStore?
    private var externalHandler: ((URL) -> Void)?

    func configure(settings: AppSettings, history: HistoryStore, openExternally: @escaping (URL) -> Void) {
        self.settings = settings
        self.history = history
        self.externalHandler = openExternally
    }

    func ensure(_ channel: Channel) {
        guard stores[channel.id] == nil, let settings, let history else { return }
        let store = WebStore(channel: channel, settings: settings, history: history)
        store.openExternally = externalHandler
        stores[channel.id] = store
        objectWillChange.send()
    }

    func store(for channel: Channel) -> WebStore? { stores[channel.id] }

    func applySettings() {
        stores.values.forEach { $0.applySettings() }
    }

    func open(_ url: URL, in channel: Channel) {
        ensure(channel)
        stores[channel.id]?.load(url)
    }
}
