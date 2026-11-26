import Foundation

// MARK: - 通用响应

/// 投票接口响应：{error, msg, comment_id}。
struct JDVoteResult: Decodable {
    let error: Int
    let msg: String?
    let comment_id: Int?
}

struct JDEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: T?

    enum CodingKeys: String, CodingKey { case code, msg, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code)
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
        data = try? c.decode(T.self, forKey: .data)
    }
}

/// 站点有些接口直接返回数组，用这个包一层让 JSONDecoder 也能吃下。
struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyDecodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyDecodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }
}

// MARK: - 内容模型

/// 时间线首页的一篇文章
struct JDPost: Codable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let excerpt: String?
    let date: String?
    let comment_count: Int?
    let thumb_img: String?
    let tucao: JDTucaoPreview?

    var detailID: Int { id }
}

struct JDTucaoPreview: Codable, Hashable {
    let nickname: String?
    let content: String?
    let avatar_ref: String?
    let avatar_type: Int?
}

struct JDTimelineGroup: Codable {
    let date: String?
    let posts: [JDPost]
}

/// 文章详情（/api/post/{id}）
struct JDPostDetail: Codable {
    let id: Int
    let title: String?
    let content: String?
    let date: String?
    let author: JDAuthor?
    let tags: [JDTag]?
    let comment_status: String?
    let comment_count: Int?
}

struct JDAuthor: Codable, Hashable {
    let nicename: String?
    let display_name: String?
}

struct JDTag: Codable, Hashable, Identifiable {
    /// 站点文章 tag 只有 name/slug，评论 tag 才带 id，所以原始 id 必须可选。
    let rawID: Int?
    let code: String?
    let name: String?
    let slug: String?
    let dimension: String?
    let scope: Int?

    enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case code, name, slug, dimension, scope
    }

    /// Identifiable 用稳定的展示值，缺 id 时用 name/slug 兜底。
    var id: String { name ?? slug ?? "tag-\(rawID ?? 0)" }
}

/// 图片流 / 热榜 / 评论详情共用的评论结构
struct JDComment: Codable, Identifiable, Hashable {
    let id: Int
    let post_id: Int?
    let author: String?
    let author_type: Int?
    let date_gmt: String?
    let user_id: Int?
    let content: String?
    let vote_positive: Int?
    let vote_negative: Int?
    let sub_comment_count: Int?
    let images: [JDImage]?
    let post_title: String?
    let ip_location: String?
    let avatar_ref: String?
    let avatar_type: Int?
    let author_membership: Int?
    let hot_tucao: JDTucaoPreview?
    let tags: [JDTag]?

    var detailID: Int { id }
}

struct JDImage: Codable, Hashable {
    let id: Int?
    let src: String?
    let src_large: String?
    let is_gif: Bool?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, src, width, height
        case src_large = "src_large"
        case is_gif = "isGIF"
    }
}

/// 文章详情页的吐槽 / 评论（/api/tucao/post/{id}），字段名与图片流评论完全不同。
struct JDArticleComment: Codable, Identifiable {
    let id: Int
    let author: String?
    let content: String?
    let date: String?
    let positive: Int?
    let negative: Int?
    let subCommentCount: Int?
    let postTitle: String?
    let location: String?
    let avatar: String?
    let userID: Int?

    enum CodingKeys: String, CodingKey {
        case id = "comment_ID"
        case author = "comment_author"
        case content = "comment_content"
        case date = "comment_date"
        case positive = "vote_positive"
        case negative = "vote_negative"
        case subCommentCount = "sub_comment_count"
        case postTitle = "post_title"
        case location = "ip_location"
        case avatar = "avatar_ref"
        case userID = "user_id"
    }

    /// 映射成图片流评论结构，复用详情页的 CommentRow。
    var asComment: JDComment {
        JDComment(
            id: id, post_id: nil, author: author, author_type: nil, date_gmt: date,
            user_id: userID, content: content, vote_positive: positive, vote_negative: negative,
            sub_comment_count: subCommentCount, images: nil, post_title: postTitle,
            ip_location: location, avatar_ref: avatar, avatar_type: nil,
            author_membership: nil, hot_tucao: nil, tags: nil
        )
    }
}

/// 图片流分页容器
struct JDCommentPage: Codable {
    let total: Int?
    let total_pages: Int?
    let current_page: Int?
    let list: [JDComment]
}

/// 鱼塘主题
struct JDForumPost: Codable, Identifiable, Hashable {
    let post_id: Int
    let title: String?
    let user_id: Int?
    let author_name: String?
    let create_time: String?
    let update_time: String?
    let oo: Int?
    let xx: Int?
    let reply_count: Int?
    let last_replier_name: String?
    let location: String?
    let avatar_ref: String?

    var id: Int { post_id }
    var detailID: Int { post_id }
}

struct JDForumPage: Codable {
    let total: Int?
    let list: [JDForumPost]
}

/// 日报条目（游客受限，list 通常为空）
struct JDDailyPage: Codable {
    let report_date: String?
    let total: Int?
    let page: Int?
    let page_size: Int?
    let is_login: Bool?
    let access: String?
    let list: [JDComment]
}

/// 吐槽列表。站点返回的是 comment_ID 那一套字段，先解成 JDArticleComment 再映射。
struct JDTucaoPage: Codable {
    let code: Int?
    let tucao: [JDArticleComment]?
    let hot_tucao: [JDArticleComment]?
}

// MARK: - 统一 Feed 项

/// 把所有频道的数据归一化成一种，列表页只认这一种类型。
struct JDFeedItem: Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case article, comment, forum
    }

    let id: Int
    let kind: Kind
    let title: String
    let body: String
    let author: String
    /// 作者 ID（评论 / 图片流有，文章时间线没有），用于按 ID 屏蔽。
    let authorID: Int?
    let date: String
    let imageURL: String?
    let commentCount: Int
    let positive: Int
    let negative: Int
    let location: String?
    let avatar: String?

    /// 首页列表左侧的大号数字（吐槽 / 评论数）
    let score: Int
    /// 首页按日期分组的标题
    let sectionDate: String?
    /// 首页条目下方的吐槽预览
    let tucaoNickname: String?
    let tucaoContent: String?
    let tucaoAvatar: String?

    /// 详情页加载用的 ID
    var detailID: Int { id }

    init(
        id: Int, kind: Kind, title: String, body: String, author: String,
        authorID: Int? = nil, date: String, imageURL: String?, commentCount: Int,
        positive: Int, negative: Int, location: String?, avatar: String?,
        score: Int = 0, sectionDate: String? = nil,
        tucaoNickname: String? = nil, tucaoContent: String? = nil, tucaoAvatar: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.author = author
        self.authorID = authorID
        self.date = date
        self.imageURL = imageURL
        self.commentCount = commentCount
        self.positive = positive
        self.negative = negative
        self.location = location
        self.avatar = avatar
        self.score = score
        self.sectionDate = sectionDate
        self.tucaoNickname = tucaoNickname
        self.tucaoContent = tucaoContent
        self.tucaoAvatar = tucaoAvatar
    }

    init(_ post: JDPost, sectionDate: String? = nil) {
        id = post.id
        kind = .article
        title = post.title ?? "煎蛋"
        body = post.excerpt ?? ""
        author = post.tucao?.nickname ?? ""
        authorID = nil
        date = post.date ?? ""
        imageURL = post.thumb_img
        commentCount = post.comment_count ?? 0
        positive = 0
        negative = 0
        location = nil
        avatar = post.tucao?.avatar_ref
        score = post.comment_count ?? 0
        self.sectionDate = sectionDate
        tucaoNickname = post.tucao?.nickname
        tucaoContent = post.tucao?.content
        tucaoAvatar = post.tucao?.avatar_ref
    }

    init(_ comment: JDComment) {
        id = comment.id
        kind = .comment
        title = comment.post_title ?? ""
        body = comment.content ?? ""
        author = comment.author ?? ""
        authorID = comment.user_id
        date = comment.date_gmt ?? ""
        imageURL = Self.firstImageURL(in: comment.content ?? "", images: comment.images)
        commentCount = comment.sub_comment_count ?? 0
        positive = comment.vote_positive ?? 0
        negative = comment.vote_negative ?? 0
        location = comment.ip_location
        avatar = comment.avatar_ref
        score = (comment.vote_positive ?? 0) - (comment.vote_negative ?? 0)
        sectionDate = nil
        tucaoNickname = nil
        tucaoContent = nil
        tucaoAvatar = nil
    }

    init(_ forum: JDForumPost) {
        id = forum.post_id
        kind = .forum
        title = forum.title ?? ""
        body = ""
        author = forum.author_name ?? ""
        authorID = forum.user_id
        date = forum.create_time ?? ""
        imageURL = nil
        commentCount = forum.reply_count ?? 0
        positive = forum.oo ?? 0
        negative = forum.xx ?? 0
        location = forum.location
        avatar = forum.avatar_ref
        score = (forum.oo ?? 0) - (forum.xx ?? 0)
        sectionDate = nil
        tucaoNickname = nil
        tucaoContent = nil
        tucaoAvatar = nil
    }

    /// 正文里的第一张图，列表页用它做缩略图；站点 images 字段常为 null，
    /// 所以主要从 content 的 <img src="..."> 里取。
    static func firstImageURL(in html: String, images: [JDImage]?) -> String? {
        if let src = images?.compactMap({ $0.src ?? $0.src_large }).first { return src }
        return JDHTML.imageURLs(in: html).first?.absoluteString
    }
}

// MARK: - 用户

struct JDUser: Codable {
    let id: Int?
    let nickname: String?
    let membership: Int?
    let avatar_ref: String?
    let avatar_type: Int?
}

// MARK: - 用户主页（游客可用）

/// 按用户 ID 查资料：/api/member/user/{id}
struct JDUserProfile: Codable {
    let id: Int?
    let nickname: String?
    let avatar_ref: String?
    let avatar_type: Int?
    let membership: Int?
    let reg_time: String?
    let primary_badge_id: Int?
    let wearing_badge_ids: [Int]?
}

/// 用户勋章列表：/api/member/user/{id}/badges
struct JDBadge: Codable, Identifiable {
    let recordID: Int?
    let badgeID: Int?
    let badge_name: String?
    let badge_icon_url: String?
    let is_wearing: Int?

    enum CodingKeys: String, CodingKey {
        case recordID = "id"
        case badgeID = "badge_id"
        case badge_name, badge_icon_url, is_wearing
    }

    var id: Int { badgeID ?? recordID ?? 0 }
    var isWearing: Bool { is_wearing == 1 }
}

struct JDBadgeList: Codable {
    let list: [JDBadge]?
}

/// 用户评论 / 吐槽列表（游客仅能看到最近 20 条）。
struct JDUserComments: Codable {
    let has_more: Bool?
    let list: [JDComment]?
    let visibility: String?
}

struct JDUserTucaos: Codable {
    let has_more: Bool?
    let list: [JDArticleComment]?
    let visibility: String?
}

// MARK: - 收藏（需登录）

/// /api/member/comment/favorites?page=
struct JDFavoritePage: Codable {
    let list: [JDFavorite]?
    let total: Int?
}

struct JDFavorite: Codable, Identifiable, Hashable {
    /// 收藏记录 ID，取消收藏时用它。
    let id: Int
    let comment_id: Int?
    let comment_author: String?
    let post_title: String?
    let comment_date: String?
    let comment_content: String?
}

// MARK: - 消息通知（需登录）

struct JDNotificationPage: Decodable {
    let list: [JDNotification]?
    let total: Int?
}

struct JDNotification: Decodable, Identifiable {
    let id: Int
    let title: String?
    let content: String?
    let created_at: String?
    /// 服务端可能给 Bool 或 0/1，统一解成 Bool。
    let readFlag: Bool
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, title, content, created_at
        case readFlag = "is_read"
        case url, link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try? c.decode(String.self, forKey: .title)
        content = try? c.decode(String.self, forKey: .content)
        created_at = try? c.decode(String.self, forKey: .created_at)
        if let b = try? c.decode(Bool.self, forKey: .readFlag) {
            readFlag = b
        } else {
            readFlag = (try? c.decode(Int.self, forKey: .readFlag)) == 1
        }
        url = (try? c.decode(String.self, forKey: .url)) ?? (try? c.decode(String.self, forKey: .link))
    }

    var isRead: Bool { readFlag }
}

struct JDCaptcha: Codable {
    let prompt: String?
    let image: String?
}

// MARK: - 工具

extension String {
    /// 从 ISO8601 / "yyyy-MM-dd HH:mm:ss" 字符串中取出适合展示的短日期。
    var jdShortDate: String {
        if let date = ISO8601DateFormatter().date(from: self) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = f.date(from: self) {
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: date)
        }
        return self
    }
}
