import Foundation

/// 煎蛋 REST API 封装。
///
/// 两个实测要点：
/// 1. 必须带正常 User-Agent，curl / 系统默认 UA 会被当成爬虫返回 data: null；
/// 2. 登录态走 Cookie，URLSession.shared 默认使用 HTTPCookieStorage.shared，
///    所以登录成功后全 App 自动共享，不需要手工搬运 token。
enum JDAPI {

    static let base = "https://jandan.net"
    static let userAgent = "Jandan iOS App"

    /// 头像静态资源域名。站点 API 返回的 avatar_ref 是 `/static/avatar/xx.png` 根相对路径，
    /// 图片实际托管在 cdn.jandan.net；拼到主域 jandan.net 会 404（主域只跑 Nuxt 页面）。
    static let avatarBase = "https://cdn.jandan.net"

    /// 头像 URL 统一解析：兼顾根相对路径、`//` 协议相对、http→https、完整 URL。
    static func avatarURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        var text = raw
        if text.hasPrefix("//") {
            text = "https:" + text
        } else if text.hasPrefix("/") {
            text = avatarBase + text
        } else if text.hasPrefix("http:") {
            text = "https:" + text.dropFirst(5)
        }
        return URL(string: text)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum APIError: LocalizedError {
        case badStatus(Int)
        case business(Int, String)
        case invalidImage
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "请求失败（HTTP \(code)）"
            case .business(_, let msg): return msg
            case .invalidImage: return "验证码图片无效"
            case .cancelled: return "已取消"
            }
        }

        /// 服务端已记录过这一票（本地状态丢失时会出现）。
        var isAlreadyVoted: Bool {
            guard case .business(let code, let msg) = self else { return false }
            return code == 1 && msg.contains("投过票")
        }
    }

    /// 统一 GET：返回 envelope.data，业务 code != 0 时抛错。
    static func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        try await request(path, method: "GET", query: query, body: nil, as: type)
    }

    static func post<T: Decodable>(
        _ path: String,
        form: [String: String],
        as type: T.Type = T.self
    ) async throws -> T {
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&")
        return try await request(
            path, method: "POST", query: [:],
            body: body.data(using: .utf8), as: type,
            contentType: "application/x-www-form-urlencoded"
        )
    }

    static func postRaw(_ path: String, form: [String: String]) async throws {
        let _: AnyDecodable = try await post(path, form: form, as: AnyDecodable.self)
    }

    /// 站点前端 apiFetch 默认用 JSON body，会员类接口用它更稳妥。
    static func postJSONRaw(_ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let envelope = try? decoder.decode(JDEnvelope<AnyDecodable>.self, from: data), envelope.code != 0 {
            throw APIError.business(envelope.code, envelope.msg.isEmpty ? "请求失败" : envelope.msg)
        }
        guard (200..<300).contains(status) else { throw APIError.badStatus(status) }
    }

    /// 少数接口（check_notice）直接返回裸数字，不走 {code,data} 信封。
    static func getRaw(_ path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw APIError.badStatus(status) }
        return data
    }

    /// 投票等少数接口用 JSON body，响应是 {error, msg, comment_id} 而不是 JDEnvelope。
    static func vote(commentID: Int, like: Bool) async throws {
        var req = URLRequest(url: URL(string: base + "/api/comment/vote")!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "comment_id": commentID,
            "like_type": like ? "pos" : "neg",
            "data_type": "comment",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let result = try JSONDecoder().decode(JDVoteResult.self, from: data)
        guard result.error == 0 else { throw APIError.business(result.error, result.msg ?? "投票失败") }
    }

    /// 举报评论：游客可调用，type 1=违法 / 2=色情 / 3=引战人身攻击。
    static func report(commentID: Int, reason: String, type: Int) async throws {
        try await postRaw("/api/report/comment", form: [
            "action": "report",
            "comment_id": "\(commentID)",
            "reason": reason,
            "type": "\(type)",
        ])
    }

    // MARK: - 发布

    /// 文章评论：站点审核后展示，发布成功不等于立即可见。
    static func createArticleComment(postID: Int, content: String, author: String, email: String) async throws {
        try await postJSONRaw("/api/comment/create_new", body: [
            "author": author,
            "email": email,
            "comment_post_id": "\(postID)",
            "content": content,
            "anonymous": false,
        ])
    }

    /// 吐槽：commentID 为父吐槽 ID，文章下新吐槽传 0 + postID。
    static func createTucao(commentID: Int, postID: Int? = nil, content: String) async throws {
        var body: [String: Any] = ["content": content, "comment_id": commentID]
        if let postID { body["comment_post_ID"] = postID }
        try await postJSONRaw("/api/tucao/create", body: body)
    }

    // MARK: - 收藏（需登录）

    static func favorites(page: Int) async throws -> JDFavoritePage {
        try await get("/api/member/comment/favorites", query: ["page": "\(page)"])
    }

    static func addFavorite(commentID: Int) async throws {
        try await postJSONRaw("/api/member/comment/favorite", body: ["comment_id": commentID])
    }

    static func removeFavorite(favoriteID: Int) async throws {
        try await postJSONRaw("/api/member/comment/favorite/delete", body: ["favorite_id": favoriteID])
    }

    // MARK: - 消息通知（需登录）

    static func notifications(page: Int) async throws -> JDNotificationPage {
        try await get("/api/member/notifications", query: ["page": "\(page)"])
    }

    /// 服务端返回裸数字或字符串数字，兼容两种并解掉可能的信封。
    static func checkNotice() async throws -> Int {
        let data = try await getRaw("/api/member/check_notice")
        if let n = try? JSONDecoder().decode(Int.self, from: data) { return n }
        if let s = try? JSONDecoder().decode(String.self, from: data), let n = Int(s) { return n }
        if let envelope = try? decoder.decode(JDEnvelope<AnyDecodable>.self, from: data) {
            guard envelope.code == 0 else { throw APIError.business(envelope.code, envelope.msg) }
            if let v = envelope.data?.value as? Int { return v }
            if let v = envelope.data?.value as? String, let n = Int(v) { return n }
        }
        return 0
    }

    static func readNotices(ids: [Int]) async throws {
        try await postJSONRaw("/api/member/read_notices", body: ["unread_ids": ids])
    }

    static func clearNotices() async throws {
        try await postJSONRaw("/api/member/clear_notices", body: [:])
    }

    // MARK: - 偏好云同步（VIP）

    /// 响应可能是 {code,data:{prefs}}，也可能直接是 {prefs}，两种都兼容。
    static func getPrefs() async throws -> [String: Any]? {
        let data = try await getRaw("/api/member/prefs")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let code = json?["code"] as? Int, code != 0 {
            throw APIError.business(code, json?["msg"] as? String ?? "同步失败")
        }
        if let envelope = json?["data"] as? [String: Any] {
            return envelope["prefs"] as? [String: Any]
        }
        return json?["prefs"] as? [String: Any]
    }

    static func updatePrefs(_ prefs: [String: Any]) async throws {
        try await postJSONRaw("/api/member/prefs", body: ["prefs": prefs])
    }

    // MARK: - 用户主页（游客可用）

    static func userProfile(_ id: Int) async throws -> JDUserProfile {
        try await get("/api/member/user/\(id)")
    }

    static func userBadges(_ id: Int) async throws -> [JDBadge] {
        let page: JDBadgeList = try await get("/api/member/user/\(id)/badges")
        return page.list ?? []
    }

    static func userComments(_ id: Int) async throws -> [JDComment] {
        let page: JDUserComments = try await get("/api/comment/user/\(id)")
        return page.list ?? []
    }

    static func userTucaos(_ id: Int) async throws -> [JDComment] {
        let page: JDUserTucaos = try await get("/api/tucao/user/\(id)")
        return (page.list ?? []).map(\.asComment)
    }

    private static func request<T: Decodable>(
        _ path: String,
        method: String,
        query: [String: String],
        body: Data?,
        as type: T.Type,
        contentType: String? = nil
    ) async throws -> T {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        // 大多数接口：{code, msg, data: T}
        if let typed = try? decoder.decode(JDEnvelope<T>.self, from: data),
           typed.code == 0, let value = typed.data {
            return value
        }

        // 吐槽等少数接口把字段直接放在顶层，没有 data 包裹。
        let meta = try decoder.decode(JDEnvelope<AnyDecodable>.self, from: data)
        guard meta.code == 0 else { throw APIError.business(meta.code, meta.msg) }
        if let root = try? decoder.decode(T.self, from: data) { return root }
        throw APIError.business(meta.code, "暂无数据")
    }
}

// MARK: - 频道数据加载

enum JDFeedSource {
    case timeline(page: Int)
    case channel(postID: Int, page: Int)
}

struct JDFeedResult {
    let items: [JDFeedItem]
    /// 下一页游标；nil 表示没有更多
    let nextPage: Int?
    let loginRequired: Bool
}

enum JDFeedLoader {

    /// 统一加载每个频道的一页数据。
    /// 图片流的 page 是从 total_pages 往回数的（站点设计如此），
    /// 所以 loadMore 时用 currentPage - 1 而不是 +1。
    static func load(source: JDFeedSource) async throws -> JDFeedResult {
        switch source {
        case .timeline(let page):
            let groups = try await JDAPI.get(
                "/api/post/timeline", query: ["page": "\(page)", "limit": "35"],
                as: [JDTimelineGroup].self
            )
            // 保留日期分组：每个 item 带上所属 group 的 date，视图据此分 section。
            let items = groups.flatMap { group in
                group.posts.map { JDFeedItem($0, sectionDate: group.date) }
            }
            return JDFeedResult(items: items, nextPage: items.isEmpty ? nil : page + 1, loginRequired: false)

        case .channel(let postID, let page):
            let result = try await JDAPI.get(
                "/api/comment/post/\(postID)",
                query: ["order": "desc", "page": "\(page)"],
                as: JDCommentPage.self
            )
            let items = result.list.map(JDFeedItem.init)
            let next = (result.current_page ?? 0) > 1 ? (result.current_page ?? 0) - 1 : nil
            return JDFeedResult(items: items, nextPage: next, loginRequired: false)
        }
    }
}

// MARK: - 频道参数

extension Channel {
    /// 图片流频道的固定 postID，来自站点 SSR 数据。
    var ugcPostID: Int? {
        switch id {
        case "pic": return 26402
        case "beauty": return 108629
        default: return nil
        }
    }

    var feedSource: JDFeedSource {
        switch id {
        case "pic", "beauty": return .channel(postID: ugcPostID ?? 26402, page: 0)
        default: return .timeline(page: 1)
        }
    }
}
