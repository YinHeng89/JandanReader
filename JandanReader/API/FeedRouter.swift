import Foundation
import SwiftUI
import Combine

/// 取代原 WebRouter：每个频道一个 FeedStore，统一分发原生内容页。
@MainActor
final class FeedRouter: ObservableObject {
    private(set) var stores: [String: FeedStore] = [:]
    private weak var history: HistoryStore?
    private var accountHandler: (() -> Void)?
    /// 从历史打开内容时请求外壳切到目标频道（不能只 push 到非当前频道的栈）。
    var switchChannel: ((Channel) -> Void)?
    /// 订阅各 store 的导航栈变化。ContentView 只观察 router，必须转发，
    /// 否则 push(.user) 这类不写历史的跳转不会触发 NavigationStack 读取新 path。
    private var pathCancellables: [String: AnyCancellable] = [:]

    func configure(history: HistoryStore, openAccount: @escaping () -> Void) {
        self.history = history
        self.accountHandler = openAccount
    }

    func ensure(_ channel: Channel) {
        guard stores[channel.id] == nil, let history else { return }
        let store = FeedStore(channel: channel, history: history)
        stores[channel.id] = store
        // path 变化时通知外层重绘，NavigationStack 才会读取到新的导航栈。
        pathCancellables[channel.id] = store.$path.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }

    func store(for channel: Channel) -> FeedStore? { stores[channel.id] }

    func openAccount() { accountHandler?() }

    /// 从历史 / 设置打开一篇文章：放到所在频道导航栈里。
    func openArticle(id: Int, title: String, kind: String, in channel: Channel) {
        ensure(channel)
        switchChannel?(channel)
        let store = stores[channel.id]
        let feedKind: JDFeedItem.Kind = kind == "forum" ? .forum : (kind == "comment" ? .comment : .article)
        store?.push(.externalArticle(id, title, feedKind))
        history?.record(id: id, title: title, kind: kind)
    }
}
