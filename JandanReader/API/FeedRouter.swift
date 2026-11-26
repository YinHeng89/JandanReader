import Foundation
import SwiftUI

/// 取代原 WebRouter：每个频道一个 FeedStore，统一分发原生内容页。
@MainActor
final class FeedRouter: ObservableObject {
    private(set) var stores: [String: FeedStore] = [:]
    private weak var history: HistoryStore?
    private var accountHandler: (() -> Void)?
    private var externalHandler: ((URL) -> Void)?
    /// 从历史打开内容时请求外壳切到目标频道（不能只 push 到非当前频道的栈）。
    var switchChannel: ((Channel) -> Void)?

    func configure(
        history: HistoryStore,
        openAccount: @escaping () -> Void,
        openExternally: @escaping (URL) -> Void
    ) {
        self.history = history
        self.accountHandler = openAccount
        self.externalHandler = openExternally
    }

    func ensure(_ channel: Channel) {
        guard stores[channel.id] == nil, let history else { return }
        stores[channel.id] = FeedStore(channel: channel, history: history)
        objectWillChange.send()
    }

    func store(for channel: Channel) -> FeedStore? { stores[channel.id] }

    func openAccount() { accountHandler?() }

    func openExternally(_ url: URL) { externalHandler?(url) }

    /// 从历史 / 设置打开一篇文章：放到所在频道导航栈里。
    func openArticle(id: Int, title: String, kind: String, in channel: Channel) {
        ensure(channel)
        switchChannel?(channel)
        let store = stores[channel.id]
        let feedKind: JDFeedItem.Kind = kind == "forum" ? .forum : (kind == "comment" ? .comment : .article)
        store?.push(.externalArticle(id, title, feedKind))
        history?.record(id: id, title: title, kind: kind)
    }

    /// 当前页面对应的分享 URL：有内容页就用内容页，否则频道首页。
    func shareURL(for channel: Channel) -> URL {
        guard let store = stores[channel.id], let top = store.path.last else { return channel.url }
        switch top {
        case .feed(let item): return item.kind == .forum
            ? URL(string: "https://jandan.net/forum/\(item.id)")!
            : URL(string: "https://jandan.net/p/\(item.id)")!
        case .article(let id), .externalArticle(let id, _, _):
            return URL(string: "https://jandan.net/p/\(id)")!
        }
    }
}
