import Foundation
import SwiftUI

/// 导航栈元素：列表点进去的内容页。
enum JDNavigation: Hashable {
    case feed(JDFeedItem)
    case article(Int)
    /// 从历史直接打开：ID + 标题 + 内容类型
    case externalArticle(Int, String, JDFeedItem.Kind)
    /// 作者个人主页：用户 ID + 昵称（昵称用于接口失败时兜底展示）
    case user(Int, String)
}

/// 每个频道一个 FeedStore，切走再切回保留列表、滚动锚点与浏览栈。
@MainActor
final class FeedStore: ObservableObject {
    let channel: Channel

    @Published private(set) var items: [JDFeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    /// 轻量提示（投票失败等），2 秒自动消失。
    @Published var toastMessage: String?
    @Published private(set) var path: [JDNavigation] = []

    /// 图片流：点击评论数后在当前条下方展开的吐槽，按评论 ID 缓存。
    @Published private(set) var expandedCommentID: Int?
    @Published private(set) var inlineComments: [Int: [JDComment]] = [:]
    @Published private(set) var inlineLoadingIDs: Set<Int> = []
    @Published private(set) var inlineErrors: [Int: String] = [:]

    private(set) var cursor: Int?
    private var loaded = false
    private weak var history: HistoryStore?

    init(channel: Channel, history: HistoryStore?) {
        self.channel = channel
        self.history = history
    }

    /// 轻量提示：连续触发时只保留最后一条。
    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toastMessage == message { self.toastMessage = nil }
        }
    }

    /// 首屏加载；已经加载过就只刷新，不丢列表。
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if loaded && !force { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await JDFeedLoader.load(source: source(page: initialPage))
            items = result.items
            cursor = result.nextPage
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 下拉刷新：保留旧列表直到新数据到达，避免刷新中被 `load()` 的 isLoading 守卫拦住导致空列表。
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await JDFeedLoader.load(source: source(page: initialPage))
            items = result.items
            cursor = result.nextPage
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let page = cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await JDFeedLoader.load(source: source(page: page))
            // 图片流翻页时按 id 去重，避免站点边界重复。
            let existing = Set(items.map(\.id))
            items += result.items.filter { !existing.contains($0.id) }
            cursor = result.nextPage
            // 上滑加载成功时清掉上一次翻页失败提示。
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 后台检查到新内容时的提示；不自动刷新，避免打断当前阅读。
    @Published private(set) var hasNewContent = false

    /// 只拉第一页最新一条做对比；失败静默，绝不打断阅读。
    func checkForNewContent() async {
        guard !isLoading, !isLoadingMore, !items.isEmpty else { return }
        do {
            let result = try await JDFeedLoader.load(source: source(page: initialPage))
            guard let newest = result.items.first else { return }
            if !items.contains(where: { $0.id == newest.id }) {
                hasNewContent = true
            }
        } catch {
            // 后台检查失败保持静默
        }
    }

    /// 点击「有新内容」：收起浮层、刷新列表。
    func acceptNewContent() async {
        hasNewContent = false
        await reload()
    }

    // MARK: 图片流投票

    func hasVoted(_ id: Int) -> Bool { VoteStore.shared.isVoted(id) }

    /// 投票方向：true=赞，false=踩，nil=未投票。
    func voteKind(_ id: Int) -> Bool? { VoteStore.shared.kind(id) }

    /// 图片流条目 id 就是评论 id，可直接投 OO / XX。
    func vote(item: JDFeedItem, like: Bool) async {
        guard item.kind == .comment, voteKind(item.id) == nil,
              items.contains(where: { $0.id == item.id }) else { return }
        // 请求成功后再改数字与高亮：失败时界面保持原样，不闪动也不需要刷新回滚。
        do {
            try await JDAPI.vote(commentID: item.id, like: like)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = items[index]
        let delta = like ? (1, 0) : (0, 1)
        let changed = JDFeedItem(
            id: original.id, kind: original.kind, title: original.title, body: original.body,
            author: original.author, authorID: original.authorID, date: original.date,
            imageURL: original.imageURL, commentCount: original.commentCount,
            positive: original.positive + delta.0, negative: original.negative + delta.1,
            location: original.location, avatar: original.avatar, score: original.score + (like ? 1 : -1),
            sectionDate: original.sectionDate, tucaoNickname: original.tucaoNickname,
            tucaoContent: original.tucaoContent, tucaoAvatar: original.tucaoAvatar
        )
        items[index] = changed
        VoteStore.shared.set(item.id, like: like)
    }

    /// 行内吐槽投票：吐槽列表里的 comment_ID 同样走 /api/comment/vote。
    func voteInline(commentID: Int, like: Bool) async {
        guard voteKind(commentID) == nil else { return }
        do {
            try await JDAPI.vote(commentID: commentID, like: like)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        guard let (itemID, index) = inlineComments.first(where: { $0.value.contains { $0.id == commentID } })
                .map({ ($0.key, $0.value.firstIndex { $0.id == commentID }!) }),
              let comment = inlineComments[itemID]?[index] else { return }
        let changed = comment.withVote(
            positive: like ? (comment.vote_positive ?? 0) + 1 : comment.vote_positive,
            negative: like ? comment.vote_negative : (comment.vote_negative ?? 0) + 1
        )
        inlineComments[itemID]![index] = changed
        VoteStore.shared.set(commentID, like: like)
    }

    /// 行内吐槽发布：成功后插入本地待审核条目，刷新后自然消失。
    @discardableResult
    func submitInline(itemID: Int, commentID: Int, content: String, author: String) async -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showToast("请填写内容")
            return false
        }
        do {
            try await JDAPI.createTucao(commentID: commentID, content: text)
            let escaped = text.replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let pending = JDComment(
                id: -Int(Date().timeIntervalSince1970), post_id: nil, author: author,
                author_type: nil, date_gmt: ISO8601DateFormatter().string(from: Date()),
                user_id: nil, content: escaped, vote_positive: 0, vote_negative: 0,
                sub_comment_count: nil, images: nil, post_title: nil, ip_location: nil,
                avatar_ref: nil, avatar_type: nil, author_membership: nil, hot_tucao: nil, tags: nil
            )
            if inlineComments[itemID] == nil { inlineComments[itemID] = [] }
            inlineComments[itemID]?.insert(pending, at: 0)
            showToast("发布成功，请等待审核")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    // MARK: 图片流评论原地展开

    /// 展开 / 收起某条图片下的评论；首次展开时才请求网络。
    func toggleInlineComments(for item: JDFeedItem) {
        if expandedCommentID == item.id {
            expandedCommentID = nil
            return
        }
        expandedCommentID = item.id
        if inlineComments[item.id] == nil {
            Task { await loadInlineComments(for: item) }
        }
    }

    func loadInlineComments(for item: JDFeedItem) async {
        let id = item.id
        guard !inlineLoadingIDs.contains(id) else { return }
        inlineLoadingIDs.insert(id)
        inlineErrors[id] = nil
        defer { inlineLoadingIDs.remove(id) }
        do {
            // 图片流条目的 ID 就是评论 ID，吐槽列表挂在这个评论下面。
            let page = try await JDAPI.get("/api/tucao/list/\(id)", as: JDTucaoPage.self)
            inlineComments[id] = (page.tucao ?? []).map(\.asComment)
        } catch {
            inlineErrors[id] = error.localizedDescription
        }
    }

    private var initialPage: Int {
        switch channel.feedSource {
        case .timeline: return 1
        case .channel: return 0
        }
    }

    private func source(page: Int) -> JDFeedSource {
        switch channel.feedSource {
        case .timeline: return .timeline(page: page)
        case .channel(let postID, _): return .channel(postID: postID, page: page)
        }
    }

    // MARK: 浏览栈

    func push(_ item: JDNavigation) {
        path.append(item)
        if case .feed(let feed) = item {
            history?.record(id: feed.detailID, title: feed.title, kind: feed.kind.rawValue)
        }
    }

    var binding: Binding<[JDNavigation]> {
        Binding(get: { self.path }, set: { self.path = $0 })
    }
}
