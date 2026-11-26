import SwiftUI

/// 正文的纯原生渲染：文本清洗 + AsyncImage 图片，不使用 WebKit / AttributedString(html:)。
/// 站点正文标签只有 h3/hr/blockquote/strong/div/a/img，这套渲染足够还原。
struct RichText: View {
    let html: String
    let baseFont: CGFloat
    var showImages: Bool = true

    @EnvironmentObject private var settings: AppSettings

    private var text: String { JDHTML.plain(html) }
    private var imageURLs: [URL] {
        guard showImages else { return [] }
        return JDHTML.imageURLs(in: html)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15 * baseFont * settings.fontScale / 100))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !imageURLs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(imageURLs, id: \.absoluteString) { url in
                        InlineAnimatedImageView(url: url)
                    }
                }
            }
        }
    }
}

/// 从 HTML 中抽出所有图片 URL（列表缩略图 / 详情页图片墙共用）。
enum JDHTML {
    static func imageURLs(in html: String) -> [URL] {
        let pattern = #"<img[^>]+src=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            var text = String(html[range])
            if text.hasPrefix("//") { text = "https:" + text }
            if text.hasPrefix("http:") { text = "https:" + text.dropFirst(5) }
            return URL(string: text)
        }
    }

    /// 站点 GIF 有两种路径：`mw600/xxx.gif` 实测只有 1 帧（静态），
    /// 动画只存在于 `large/xxx.gif`；缩略图还可能带 `.gif.webp` 后缀。
    static func isGIF(_ url: URL) -> Bool {
        url.absoluteString.localizedCaseInsensitiveContains(".gif")
    }

    /// 取 GIF 文件名（含 .gif，剥掉 .webp），例如 thumb180/a.gif.webp → a.gif。
    private static func gifFileName(_ url: URL) -> String? {
        let text = url.absoluteString
        let pattern = #"/([^/?#]+?\.gif)(?:\.webp)?(?:[?#].*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// 动画原图：`https://host/large/xxx.gif`（逐帧解码的兜底版本）。
    static func animatedGIFURL(_ url: URL) -> URL? {
        guard let name = gifFileName(url), let host = url.host else { return nil }
        return URL(string: "https://\(host)/large/\(name)")
    }

    /// 站点前端播放 GIF 实际用的是同名 mp4（H.264 边下边播，体积约为 GIF 的一半）。
    /// 例：`large/xxx.gif` → `large/xxx.mp4`。仅 img.toto.im 支持，用前需探测。
    static func animatedVideoURL(_ url: URL) -> URL? {
        guard let name = gifFileName(url), let host = url.host else { return nil }
        // gifFileName 含 .gif 后缀（如 a.gif），mp4 用同名去后缀：a.gif → a.mp4。
        let mp4Name = name.replacingOccurrences(of: ".gif", with: ".mp4", options: .caseInsensitive)
        return URL(string: "https://\(host)/large/\(mp4Name)")
    }

    /// 加载动画前的轻量占位：600px webp 静态帧，几十 KB。
    static func staticGIFURL(_ url: URL) -> URL? {
        guard let name = gifFileName(url), let host = url.host else { return nil }
        return URL(string: "https://\(host)/mw600/\(name).webp")
    }

    /// 静态图尺寸切换；GIF 一律走动画原图，避免拿到单帧静态版本。
    static func displayURL(_ url: URL, thumbnail: Bool) -> URL {
        guard !thumbnail else { return url }
        if isGIF(url) { return animatedGIFURL(url) ?? url }
        let text = url.absoluteString
        let pattern = #"/(mw600|mw1024|large|thumb180)/"#
        let replaced = text.replacingOccurrences(of: pattern, with: "/mw1024/", options: .regularExpression)
        return URL(string: replaced) ?? url
    }

    /// 去掉 HTML 标签，用作纯文本摘要
    static func plain(_ html: String) -> String {
        let stripped = html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>|</div>|</blockquote>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
