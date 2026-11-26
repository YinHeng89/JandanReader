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

    let item: JDFeedItem

    init(item: JDFeedItem) { self.item = item }

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

    /// 已投票的评论及方向（true=赞，false=踩），站点限制同一条只能投一次。
    @Published private(set) var votedKinds: [Int: Bool] = [:]

    func hasVoted(_ commentID: Int) -> Bool { votedKinds[commentID] != nil }

    /// 投票方向：true=赞，false=踩，nil=未投票。
    func voteKind(_ commentID: Int) -> Bool? { votedKinds[commentID] }

    /// 投票：乐观更新，失败回滚。评论与吐槽都走同一个投票接口。
    func vote(commentID: Int, like: Bool) async {
        guard voteKind(commentID) == nil else { return }
        if let index = comments.firstIndex(where: { $0.id == commentID }) {
            await applyVote(commentID: commentID, like: like, list: .comments, index: index)
        } else if let index = tucaos.firstIndex(where: { $0.id == commentID }) {
            await applyVote(commentID: commentID, like: like, list: .tucaos, index: index)
        }
    }

    private enum VoteList { case comments, tucaos }

    private func applyVote(commentID: Int, like: Bool, list: VoteList, index: Int) async {
        let original: JDComment
        switch list {
        case .comments: original = comments[index]
        case .tucaos: original = tucaos[index]
        }
        let changed = like
            ? original.withVote(positive: (original.vote_positive ?? 0) + 1)
            : original.withVote(negative: (original.vote_negative ?? 0) + 1)
        switch list {
        case .comments: comments[index] = changed
        case .tucaos: tucaos[index] = changed
        }
        votedKinds[commentID] = like
        do {
            try await JDAPI.vote(commentID: commentID, like: like)
        } catch {
            switch list {
            case .comments: comments[index] = original
            case .tucaos: tucaos[index] = original
            }
            votedKinds.removeValue(forKey: commentID)
            errorMessage = error.localizedDescription
        }
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
