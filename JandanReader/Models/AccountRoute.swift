import Foundation

/// 用户中心、会员、消息等「功能页」的 URL 判定与标题。
///
/// 这些页面与 10 个内容频道不是同一层级，需要在独立页面里呈现；
/// 否则寄身在频道 WebView 里时，频道条的选中态必然与内容不符。
///
/// 注意 `/new/forum`（鱼塘）、`/new/daily`（日报）虽然在 `/new/` 下，
/// 但属于内容频道，不能拦。
enum AccountRoute {
    private static let prefixes = ["/new/member", "/new/vip"]

    static let memberURL = URL(string: "https://jandan.net/new/member")!

    static func isAccount(_ url: URL) -> Bool {
        guard let host = url.host, host.hasSuffix("jandan.net") else { return false }
        let path = url.path
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 独立页标题跟随当前功能页，站内跳转（用户中心 → 消息 → 会员）也会更新。
    static func title(for url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/new/member/message") { return "消息通知" }
        if path.hasPrefix("/new/vip") { return "订阅会员" }
        return "用户中心"
    }
}
