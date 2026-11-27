import Foundation
import SwiftUI

/// 详情页数据容器。用 ObservableObject 而非 @State，规避 Xcode 27.2 -device 上的宏展开问题。
@MainActor
final class DetailStore: ObservableObject {
    enum Content {
        case article(JDPostDetail)
        case comment(JDComment)
        case forum(String, String) // 标题 + 正文（站点论坛接口给的是 HTML 片段）
    }

    @Published private(set) var content: Content?
    @Published private(set) var comments: [JDComment] = []
    @Published private(set) var tucaos: [JDComment] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    /// 投票失败等轻量提示，2 秒自动消失。
    @Published var toastMessage: String?

    let item: JDFeedItem

    init(item: JDFeedItem) { self.item = item }

    /// 轻量提示：连续触发时只保留最后一条。
    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toastMessage == message { self.toastMessage = nil }
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch item.kind {
            case .article:
                let detail = try await JDAPI.get("/api/post/\(item.id)", as: JDPostDetail.self)
                content = .article(detail)
                // 文章页评论走 /api/tucao/post/{id}（字段名是 comment_ID 那一套），
                // 而不是图片流的 /api/comment/post/{id}——后者对文章一律返回 code:1。
                if let list = try? await JDAPI.get(
                    "/api/tucao/post/\(item.id)", as: [JDArticleComment].self
                ) {
                    comments = list.map(\.asComment)
                }
            case .comment:
                let detail = try await JDAPI.get("/api/comment/info/\(item.id)", as: JDComment.self)
                content = .comment(detail)
                if let page = try? await JDAPI.get("/api/tucao/list/\(item.id)", as: JDTucaoPage.self) {
                    tucaos = (page.tucao ?? []).map(\.asComment)
                }
            case .forum:
                let page = try await JDAPI.get("/api/forum/posts/\(item.id)", as: JDForumPage.self)
                let title = page.list.first?.title ?? item.title
                content = .forum(title, item.body)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func hasVoted(_ commentID: Int) -> Bool { VoteStore.shared.isVoted(commentID) }

    /// 投票方向：true=赞，false=踩，nil=未投票。
    func voteKind(_ commentID: Int) -> Bool? { VoteStore.shared.kind(commentID) }

    /// 投票：请求成功后才改数字与高亮，失败时界面保持原样。
    func vote(commentID: Int, like: Bool) async {
        guard voteKind(commentID) == nil else { return }
        if comments.contains(where: { $0.id == commentID }) {
            await applyVote(commentID: commentID, like: like, list: .comments)
        } else if tucaos.contains(where: { $0.id == commentID }) {
            await applyVote(commentID: commentID, like: like, list: .tucaos)
        }
    }

    /// 发布评论 / 吐槽。站点审核制，成功后插入本地待审核条目，刷新后自然消失。
    @discardableResult
    func submit(content: String, author: String) async -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showToast("请填写内容")
            return false
        }
        do {
            switch item.kind {
            case .article:
                try await JDAPI.createArticleComment(
                    postID: item.id, content: text, author: author, email: ""
                )
                comments.insert(JDPendingComment.make(content: text, author: author), at: 0)
            case .comment, .forum:
                try await JDAPI.createTucao(commentID: item.id, content: text)
                tucaos.insert(JDPendingComment.make(content: text, author: author), at: 0)
            }
            showToast("发布成功，请等待审核")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    private enum VoteList { case comments, tucaos }

    private func applyVote(commentID: Int, like: Bool, list: VoteList) async {
        do {
            try await JDAPI.vote(commentID: commentID, like: like)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        // 网络期间列表可能刷新，旧 index 会指向别的评论；按 id 重新定位并复核。
        let index: Int?
        switch list {
        case .comments: index = comments.firstIndex(where: { $0.id == commentID })
        case .tucaos: index = tucaos.firstIndex(where: { $0.id == commentID })
        }
        guard let index else { return }
        switch list {
        case .comments:
            let original = comments[index]
            comments[index] = like
                ? original.withVote(positive: (original.vote_positive ?? 0) + 1)
                : original.withVote(negative: (original.vote_negative ?? 0) + 1)
        case .tucaos:
            let original = tucaos[index]
            tucaos[index] = like
                ? original.withVote(positive: (original.vote_positive ?? 0) + 1)
                : original.withVote(negative: (original.vote_negative ?? 0) + 1)
        }
        VoteStore.shared.set(commentID, like: like)
    }
}

/// JDComment 字段是 let，投票需要可写副本。
extension JDComment {
    /// 用成员构造一个只改票数的副本（Codable 所有字段都在，避免用反射）。
    func withVote(positive: Int? = nil, negative: Int? = nil) -> JDComment {
        JDComment(
            id: id, post_id: post_id, author: author, author_type: author_type,
            date_gmt: date_gmt, user_id: user_id, content: content,
            vote_positive: positive ?? vote_positive, vote_negative: negative ?? vote_negative,
            sub_comment_count: sub_comment_count, images: images, post_title: post_title,
            ip_location: ip_location, avatar_ref: avatar_ref, avatar_type: avatar_type,
            author_membership: author_membership, hot_tucao: hot_tucao, tags: tags
        )
    }
}
