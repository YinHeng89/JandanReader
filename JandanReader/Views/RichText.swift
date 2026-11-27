import SwiftUI
import Foundation

/// HTML 片段的三种渲染单元，按顺序保留图文混排与链接。
enum RichBlock {
    case text(String)
    case image(URL)
    case link(String, URL)
}

/// 正文的纯原生渲染：按 HTML 顺序渲染文本 / 图片 / 链接，不使用 WebKit。
/// 站点正文标签主要是 h3/hr/blockquote/strong/div/a/img，这套渲染足够还原。
struct RichText: View {
    let html: String
    let baseFont: CGFloat
    let showImages: Bool
    /// 在 init 里一次性解析，避免每次 body 重绘都跑一遍正则。
    private let blocks: [RichBlock]

    @EnvironmentObject private var settings: AppSettings

    init(html: String, baseFont: CGFloat, showImages: Bool = true) {
        self.html = html
        self.baseFont = baseFont
        self.showImages = showImages
        self.blocks = JDHTML.blocks(in: html, includeImages: showImages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .text(let value):
                    Text(value)
                        .font(.system(size: 15 * baseFont * settings.fontScale / 100))
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let url):
                    InlineAnimatedImageView(url: url)
                case .link(let title, let url):
                    Link(title, destination: url)
                        .font(.system(size: 15 * baseFont * settings.fontScale / 100))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// HTML 解析工具：正则只编译一次，实体按标准解码，图片按出现位置切块。
enum JDHTML {
    private static let tagPattern = #"<[^>]+>"#
    private static let tagRegex = try! NSRegularExpression(pattern: tagPattern)
    private static let breakRegex = try! NSRegularExpression(
        pattern: #"<br\s*/?>"#, options: .caseInsensitive)
    private static let closeRegex = try! NSRegularExpression(
        pattern: #"</p>|</div>|</blockquote>"#, options: .caseInsensitive)
    private static let imageRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\b(?:src|data-original|data-src)=["']([^"']+)["']"#,
        options: .caseInsensitive)
    /// 一次匹配 img 标签或完整的 a 标签；[\s\S] 保证跨行也能命中。
    private static let blockRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>|<a\b[^>]*>[\s\S]*?</a>"#, options: .caseInsensitive)
    private static let srcRegex = try! NSRegularExpression(
        pattern: #"\b(?:src|data-original|data-src)=["']([^"']+)["']"#,
        options: .caseInsensitive)
    private static let hrefRegex = try! NSRegularExpression(
        pattern: #"\bhref=["']([^"']+)["']"#, options: .caseInsensitive)
    private static let entityRegex = try! NSRegularExpression(
        pattern: #"&(?:#x[0-9A-Fa-f]+|#\d+|[A-Za-z]+);"#)

    private static let entities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
        "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’",
        "&middot;": "·", "&times;": "×", "&copy;": "©",
    ]

    /// 按 HTML 出现顺序拆成文本 / 图片 / 链接块，图文不再被分成两段。
    static func blocks(in html: String, includeImages: Bool = true) -> [RichBlock] {
        let ns = NSRange(html.startIndex..., in: html)
        let matches = blockRegex.matches(in: html, range: ns)
        guard !matches.isEmpty else {
            let text = plain(html)
            return text.isEmpty ? [] : [.text(text)]
        }
        var result: [RichBlock] = []
        var cursor = html.startIndex
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            appendText(String(html[cursor..<range.lowerBound]), to: &result)
            let tag = String(html[range])
            if tag.lowercased().hasPrefix("<img") {
                if includeImages, let url = firstURL(in: tag, using: srcRegex) {
                    result.append(.image(url))
                }
            } else {
                let title = plain(tag)
                guard !title.isEmpty else { cursor = range.upperBound; continue }
                if let url = firstURL(in: tag, using: hrefRegex) {
                    result.append(.link(title, url))
                } else {
                    result.append(.text(title))
                }
            }
            cursor = range.upperBound
        }
        appendText(String(html[cursor...]), to: &result)
        return result
    }

    private static func appendText(_ raw: String, to result: inout [RichBlock]) {
        let text = plain(raw)
        guard !text.isEmpty else { return }
        // 相邻文本片段合并，避免正文被图片切成很多个 Text 导致行距异常。
        if case .text(let previous)? = result.last {
            result[result.count - 1] = .text(previous + "\n" + text)
        } else {
            result.append(.text(text))
        }
    }

    private static func firstURL(in text: String, using regex: NSRegularExpression) -> URL? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return normalizedURL(String(text[range]))
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("//") { text = "https:" + text }
        else if text.hasPrefix("http:") { text = "https:" + text.dropFirst(5) }
        else if text.hasPrefix("/") { text = JDAPI.avatarBase + text }
        return URL(string: text)
    }

    /// 兼容旧调用：抽出全部图片 URL（缩略图 / 图片墙共用）。
    static func imageURLs(in html: String) -> [URL] {
        let matches = imageRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return normalizedURL(String(html[range]))
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
        let mp4Name = name.replacingOccurrences(of: ".gif", with: ".mp4", options: .caseInsensitive)
        return URL(string: "https://\(host)/large/\(mp4Name)")
    }

    /// 加载动画前的轻量占位：600px webp 静态帧，几十 KB。
    static func staticGIFURL(_ url: URL) -> URL? {
        guard let name = gifFileName(url), let host = url.host else { return nil }
        return URL(string: "https://\(host)/mw600/\(name).webp")
    }

    /// 尺寸路径统一替换：mw600 / mw1024 / large / thumb180 …
    static func sizedURL(_ url: URL, size: String) -> URL {
        let text = url.absoluteString
        let pattern = #"/(mw\d+|large|thumb\d+|small|medium|original)/"#
        let replaced = text.replacingOccurrences(
            of: pattern, with: "/\(size)/", options: .regularExpression
        )
        return URL(string: replaced) ?? url
    }

    /// 显示用 URL：开启缩略图走 600px 小图，关闭走 large 原图。
    /// 旧实现 thumbnail=true 直接返回原 URL（开关无效），thumbnail=false 又把所有
    /// 尺寸改成 mw1024（把 large 原图降采样），两个方向都不对。
    static func displayURL(_ url: URL, thumbnail: Bool) -> URL {
        if isGIF(url) {
            return thumbnail
                ? (staticGIFURL(url) ?? url)
                : (animatedGIFURL(url) ?? url)
        }
        return sizedURL(url, size: thumbnail ? "mw600" : "large")
    }

    /// 分享用：始终取站点原图（large），GIF 取动画版本。
    static func originalURL(_ url: URL) -> URL {
        if isGIF(url) { return animatedGIFURL(url) ?? url }
        return sizedURL(url, size: "large")
    }

    /// 去掉 HTML 标签，用作纯文本摘要；实体按标准解码（含数字实体）。
    static func plain(_ html: String) -> String {
        var text = html
        text = replacing(breakRegex, in: text, with: "\n")
        text = replacing(closeRegex, in: text, with: "\n")
        text = replacing(tagRegex, in: text, with: "")
        text = decodeEntities(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String,
                                  with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }

    /// 一次性扫描所有实体并替换，避免 `&amp;#39;` 被二次解码。
    private static func decodeEntities(_ text: String) -> String {
        let matches = entityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let entity = String(text[range])
            if let mapped = entities[entity] ?? entities[entity.lowercased()] {
                result += mapped
            } else if let scalar = numericScalar(entity) {
                result.append(Character(scalar))
            } else {
                result += entity
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func numericScalar(_ entity: String) -> Unicode.Scalar? {
        let body = entity.dropFirst(2).dropLast() // 去 &# 与 ;
        let value: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return scalar
    }
}
