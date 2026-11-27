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
    /// 分页数据源可注入，便于用确定性假数据回归「刷新 / 翻页」竞态。
    typealias PageLoader = (JDFeedSource) async throws -> JDFeedResult

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

    /// 游标必须可观察：某一页去重后可能一条新内容都没有，items.count 不变，
    /// 视图要靠 cursor 的变化继续调度下一页。
    @Published private(set) var cursor: Int?
    /// 每次首屏 / 下拉刷新自增。在途 loadMore 回来时若 epoch 变了就把结果整体作废，
    /// 否则刷新前那一页的响应会覆盖新列表的 cursor，导致旧内容再也加载不出来。
    private var epoch = 0
    private var loaded = false
    private weak var history: HistoryStore?
    private let pageLoader: PageLoader

    init(
        channel: Channel,
        history: HistoryStore?,
        loader: @escaping PageLoader = JDFeedLoader.load(source:)
    ) {
        self.channel = channel
        self.history = history
        self.pageLoader = loader
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
        epoch += 1
        let token = epoch
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        defer { if epoch == token { isLoading = false } }
        do {
            let result = try await pageLoader(source(page: initialPage))
            guard epoch == token else { return }
            applyFirstPage(result)
        } catch {
            guard epoch == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 下拉刷新：保留旧列表直到新数据到达，避免刷新中被 `load()` 的 isLoading 守卫拦住导致空列表。
    func reload() async {
        guard !isLoading else { return }
        epoch += 1
        let token = epoch
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        // 刷新会换掉整份列表：收起评论区，避免它指向已消失的条目并永久阻塞翻页。
        expandedCommentID = nil
        inlineErrors = [:]
        defer { if epoch == token { isLoading = false } }
        do {
            let result = try await pageLoader(source(page: initialPage))
            guard epoch == token else { return }
            applyFirstPage(result)
        } catch {
            guard epoch == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyFirstPage(_ result: JDFeedResult) {
        items = result.items
        cursor = result.nextPage
        loaded = true
    }

    /// 翻页：一次触发最多连续跳过 4 个「整页都是重复」的页面。
    /// 站点按页号取数据，刷新后分页边界会平移，按 id 去重后可能一页新内容都没有；
    /// 旧实现只靠 items.count 变化驱动哨兵，遇到空页就永久停在转圈。
    func loadMore() async {
        guard !isLoading, !isLoadingMore, cursor != nil else { return }
        let token = epoch
        isLoadingMore = true
        errorMessage = nil
        defer { if epoch == token { isLoadingMore = false } }
        do {
            var appended = 0
            for _ in 0..<5 {
                guard let page = cursor else { break }
                let result = try await pageLoader(source(page: page))
                // 刷新期间旧页响应一律作废，不能追加、更不能覆盖 cursor。
                guard epoch == token else { return }
                let existing = Set(items.map(\.id))
                let fresh = result.items.filter { !existing.contains($0.id) }
                if !fresh.isEmpty { items += fresh }
                cursor = advancedCursor(from: page, result: result)
                appended += fresh.count
                if appended > 0 || cursor == nil { break }
            }
            if appended == 0, cursor != nil {
                // 明确给出可点击重试的状态，绝不留下一个永远转圈的空白哨兵。
                errorMessage = "没有加载到新内容，点击重试"
            }
        } catch {
            guard epoch == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 站点偶尔回传与请求相同的页号；必须强制往前推一格，否则会反复请求同一页。
    private func advancedCursor(from page: Int, result: JDFeedResult) -> Int? {
        guard let next = result.nextPage else { return nil }
        guard next != page else {
            switch channel.feedSource {
            case .timeline: return page + 1
            case .channel: return page > 1 ? page - 1 : nil
            }
        }
        return next
    }

    /// 后台检查到新内容时的提示；不自动刷新，避免打断当前阅读。
    @Published private(set) var hasNewContent = false

    /// 只拉第一页最新一条做对比；失败静默，绝不打断阅读。
    func checkForNewContent() async {
        guard !isLoading, !isLoadingMore, !items.isEmpty else { return }
        let token = epoch
        do {
            let result = try await pageLoader(source(page: initialPage))
            guard epoch == token, let newest = result.items.first else { return }
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
        // 网络期间列表可能已刷新，必须按 id 重新定位。
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

    /// 行内吐槽投票：显式传 itemID，按 comment.id 精确定位，
    /// 不再用字典 first(where:) + 强制解包（列表刷新后会把票加到别的评论）。
    func voteInline(itemID: Int, commentID: Int, like: Bool) async {
        guard voteKind(commentID) == nil,
              inlineComments[itemID]?.contains(where: { $0.id == commentID }) == true else { return }
        do {
            try await JDAPI.vote(commentID: commentID, like: like)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        guard var list = inlineComments[itemID],
              let index = list.firstIndex(where: { $0.id == commentID }) else { return }
        let comment = list[index]
        let changed = comment.withVote(
            positive: like ? (comment.vote_positive ?? 0) + 1 : comment.vote_positive,
            negative: like ? comment.vote_negative : (comment.vote_negative ?? 0) + 1
        )
        list[index] = changed
        inlineComments[itemID] = list
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
            let pending = JDPendingComment.make(content: text, author: author)
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
    /// 只往当前条下面插入一行，不滚动列表，页面位置保持不变。
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
