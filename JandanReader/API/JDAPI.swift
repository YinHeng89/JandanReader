import Foundation

/// 煎蛋 REST API 封装。
///
/// 三个实测要点：
/// 1. 必须带正常 User-Agent，curl / 系统默认 UA 会被当成爬虫返回 data: null；
/// 2. 登录态走 Cookie，URLSession.shared 默认使用 HTTPCookieStorage.shared，
///    所以登录成功后全 App 自动共享，不需要手工搬运 token；
/// 3. 站点多数接口返回 `{code,msg,data}`（code 0 成功），但投票等老接口返回
///    `{error,msg}`。所有写接口必须先做统一业务码校验，否则会出现「假成功」。
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
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "请求失败（HTTP \(code)）"
            case .business(_, let msg): return msg
            case .invalidImage: return "验证码图片无效"
            case .cancelled: return "已取消"
            case .invalidResponse: return "服务端响应格式异常"
            }
        }

        /// 服务端已记录过这一票（本地状态丢失时会出现）。
        var isAlreadyVoted: Bool {
            guard case .business(let code, let msg) = self else { return false }
            return code == 1 && msg.contains("投过票")
        }
    }

    // MARK: - 统一业务码校验

    /// 站点业务失败有几种信封，统一在这里判定：
    /// `{code:非0,msg}` / `{error:非0|字符串,msg}` / `{success:false}` / `{status:"error"}`。
    /// 裸数字、裸数组、纯文本不是错误信封，直接放行（check_notice 等接口用）。
    enum JDResponse {
        static func validate(_ data: Data) throws {
            guard let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any] else { return }

            if let code = intValue(object["code"]) {
                if code != 0 { throw APIError.business(code, message(object) ?? "请求失败") }
                return
            }
            if let error = object["error"] {
                if let code = intValue(error) {
                    if code != 0 { throw APIError.business(code, message(object) ?? "请求失败") }
                } else {
                    let text = (error as? String) ?? message(object) ?? "请求失败"
                    throw APIError.business(1, text)
                }
                return
            }
            if let success = object["success"] as? Bool, !success {
                throw APIError.business(1, message(object) ?? "请求失败")
            }
            if let status = object["status"] as? String,
               ["error", "fail", "failed"].contains(status.lowercased()) {
                throw APIError.business(1, message(object) ?? "请求失败")
            }
        }

        /// code 可能是 Int / NSNumber / 数字字符串。
        static func intValue(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let n = value as? NSNumber { return n.intValue }
            if let s = value as? String { return Int(s) }
            return nil
        }

        static func message(_ object: [String: Any]) -> String? {
            for key in ["msg", "message", "error_msg"] {
                if let s = object[key] as? String, !s.isEmpty { return s }
            }
            return nil
        }
    }

    // MARK: - 请求基座

    /// 所有请求的唯一出口：统一 User-Agent / Referer、HTTP 状态与业务码校验。
    private static func rawRequest(
        _ path: String,
        method: String,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: base + path) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(base + "/", forHTTPHeaderField: "Referer")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }
        try JDResponse.validate(data)
        return data
    }

    /// 严格的 form-urlencoded 编码：非 ASCII 逐字节百分编码，不会失败，
    /// 因此无需 `?? value` 兜底（旧实现会把明文参数拼进请求体造成注入风险）。
    static func encodeForm(_ form: [String: String]) throws -> Data {
        var parts: [String] = []
        for (key, value) in form.sorted(by: { $0.key < $1.key }) {
            parts.append("\(percentEncode(key))=\(percentEncode(value))")
        }
        return Data(parts.joined(separator: "&").utf8)
    }

    private static func percentEncode(_ text: String) -> String {
        // 必须是纯 ASCII 白名单：CharacterSet.alphanumerics 包含 Unicode 字母
        // （0xE4 = ä、0xE6 = æ…），会让 UTF-8 的高字节漏出去不被百分编码。
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*"
        )
        var out = ""
        for byte in Array(text.utf8) {
            let scalar = UnicodeScalar(byte)
            if byte == 0x20 {
                out.append("+")
            } else if allowed.contains(scalar) {
                out.append(Character(scalar))
            } else {
                out.append(String(format: "%%%02X", Int(byte)))
            }
        }
        return out
    }

    // MARK: - GET / POST

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
        let body = try encodeForm(form)
        return try await request(
            path, method: "POST", query: [:], body: body, as: type,
            contentType: "application/x-www-form-urlencoded"
        )
    }

    /// 只关心成败的 form 请求：不再借道 AnyDecodable，避免老接口 `{error,msg}` 被当成成功。
    static func postRaw(_ path: String, form: [String: String]) async throws {
        let body = try encodeForm(form)
        _ = try await rawRequest(
            path, method: "POST", body: body,
            contentType: "application/x-www-form-urlencoded"
        )
    }

    /// 发布 / 收藏 / 通知 / 偏好同步用 JSON body。
    static func postJSONRaw(_ path: String, body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await rawRequest(path, method: "POST", body: data, contentType: "application/json")
    }

    /// 少数接口（check_notice）直接返回裸数字，不走 {code,data} 信封。
    static func getRaw(_ path: String) async throws -> Data {
        try await rawRequest(path, method: "GET")
    }

    private static func request<T: Decodable>(
        _ path: String,
        method: String,
        query: [String: String],
        body: Data?,
        as type: T.Type,
        contentType: String? = nil
    ) async throws -> T {
        let data = try await rawRequest(
            path, method: method, query: query, body: body, contentType: contentType
        )

        // 大多数接口：{code, msg, data: T}
        if let typed = try? decoder.decode(JDEnvelope<T>.self, from: data),
           typed.code == 0, let value = typed.data {
            return value
        }
        // 吐槽、时间线等接口把字段直接放在顶层，没有 data 包裹。
        if let root = try? decoder.decode(T.self, from: data) { return root }
        // 业务码为 0 但 data 为空：只允许「不关心内容」的调用方通过。
        if T.self == AnyDecodable.self, let empty = AnyDecodable(NSNull()) as? T {
            return empty
        }
        throw APIError.invalidResponse
    }

    // MARK: - 投票 / 举报

    /// 投票接口响应是 {error, msg, comment_id}，统一校验后再做一次类型兜底。
    static func vote(commentID: Int, like: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "comment_id": commentID,
            "like_type": like ? "pos" : "neg",
            "data_type": "comment",
        ])
        let data = try await rawRequest(
            "/api/comment/vote", method: "POST", body: body, contentType: "application/json"
        )
        if let result = try? decoder.decode(JDVoteResult.self, from: data), result.error != 0 {
            throw APIError.business(result.error, result.msg ?? "投票失败")
        }
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
            return JDFeedResult(items: items, nextPage: items.isEmpty ? nil : page + 1)

        case .channel(let postID, let page):
            let result = try await JDAPI.get(
                "/api/comment/post/\(postID)",
                query: ["order": "desc", "page": "\(page)"],
                as: JDCommentPage.self
            )
            let items = result.list.map(JDFeedItem.init)
            let next = (result.current_page ?? 0) > 1 ? (result.current_page ?? 0) - 1 : nil
            return JDFeedResult(items: items, nextPage: next)
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
