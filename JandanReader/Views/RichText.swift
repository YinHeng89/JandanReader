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
        return JDHTML.imageURLs(in: html).map { JDHTML.displayURL($0, thumbnail: settings.cleanMode) }
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
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                Color(.secondarySystemBackground)
                                    .frame(height: 140)
                                    .overlay(ProgressView())
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    /// 官方两套尺寸：列表 `mw600`、详情 `mw1024`；GIF 大图走 `large/xxx.gif`。
    /// `thumbnail = true` 用列表小图，false 用原图，对应设置里的「显示缩略图」。
    static func displayURL(_ url: URL, thumbnail: Bool) -> URL {
        guard !thumbnail else { return url }
        let text = url.absoluteString
        let isGIF = text.lowercased().hasSuffix(".gif")
        let target = isGIF ? "large" : "mw1024"
        let pattern = #"/(mw600|mw1024|large|thumb180)/"#
        let replaced = text.replacingOccurrences(of: pattern, with: "/\(target)/", options: .regularExpression)
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
