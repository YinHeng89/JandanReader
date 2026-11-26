import Foundation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id: Int { postID }
    let postID: Int
    let title: String
    let kind: String
    let date: Date

    /// 用站点真实 URL 结构还原，方便「用 Safari 打开」。
    var url: URL {
        let prefix = kind == "forum" ? "forum" : "p"
        return URL(string: "https://jandan.net/\(prefix)/\(postID)")!
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    private let key = "jd_reading_history_v2"
    private let limit = 80
    private let defaults = UserDefaults.standard

    @Published private(set) var items: [HistoryItem] = []

    init() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data)
        else { return }
        items = decoded
    }

    /// 内容页统一在这里记录，列表页不进历史。
    func record(id: Int, title: String, kind: String) {
        guard id > 0 else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        var next = items.filter { $0.postID != id }
        next.insert(
            HistoryItem(postID: id, title: cleanTitle, kind: kind, date: Date()),
            at: 0
        )
        items = Array(next.prefix(limit))
        save()
    }

    /// 兼容旧调用方式（URL 末尾数字即文章 ID）
    func record(title: String?, url: URL?) {
        guard let url,
              url.host?.hasSuffix("jandan.net") == true,
              let last = url.pathComponents.last,
              let id = Int(last)
        else { return }
        record(id: id, title: title ?? "", kind: "article")
    }

    func clear() {
        items = []
        defaults.removeObject(forKey: key)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
