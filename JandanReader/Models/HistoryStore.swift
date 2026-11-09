import Foundation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let title: String
    let url: String
    let date: Date
}

@MainActor
final class HistoryStore: ObservableObject {
    private let key = "jd_reading_history"
    private let limit = 80
    private let defaults = UserDefaults.standard

    @Published private(set) var items: [HistoryItem] = []

    init() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data)
        else { return }
        items = decoded
    }

    /// 只记录内容页（/p/123、/pic/123 ...），列表页不进历史。
    func record(title: String?, url: URL?) {
        guard let url,
              url.host?.hasSuffix("jandan.net") == true,
              url.path.range(of: #"^/\w+/\d+/?$"#, options: .regularExpression) != nil,
              let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanTitle.isEmpty
        else { return }

        let absolute = url.absoluteString
        var next = items.filter { $0.url != absolute }
        next.insert(HistoryItem(title: cleanTitle, url: absolute, date: Date()), at: 0)
        items = Array(next.prefix(limit))
        save()
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
