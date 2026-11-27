import Foundation
import SwiftUI

/// 收藏状态：分页拉全量用于「是否已收藏」判断和列表展示。
/// 服务端没有批量「是否已收藏」接口；旧实现只拉第一页 20 条，
/// 超出部分既看不到也取消不了收藏，这里按 total 逐页补齐。
@MainActor
final class FavoriteStore: ObservableObject {
    static let shared = FavoriteStore()

    /// 防御性上限，避免服务端 total 异常时无限翻页。
    private static let maxPages = 20

    @Published private(set) var entries: [JDFavorite] = []
    @Published private(set) var commentIDs: Set<Int> = []
    @Published private(set) var isLoading = false
    @Published var toastMessage: String?

    func isFavorite(_ commentID: Int) -> Bool { commentIDs.contains(commentID) }

    func clear() {
        entries = []
        commentIDs = []
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toastMessage == message { self.toastMessage = nil }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        var all: [JDFavorite] = []
        var seen = Set<Int>()
        do {
            for page in 1...Self.maxPages {
                let result = try await JDAPI.favorites(page: page)
                let list = result.list ?? []
                for entry in list where !seen.contains(entry.id) {
                    seen.insert(entry.id)
                    all.append(entry)
                }
                if list.isEmpty { break }
                if let total = result.total, all.count >= total { break }
            }
        } catch {
            // 某一页失败时保留已取到的部分，不把整份收藏列表清空。
        }
        guard !all.isEmpty else { return }
        entries = all
        commentIDs = Set(all.compactMap(\.comment_id))
    }

    @discardableResult
    func add(commentID: Int) async -> Bool {
        do {
            try await JDAPI.addFavorite(commentID: commentID)
            await refresh()
            showToast("已收藏")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func remove(commentID: Int) async -> Bool {
        guard let entry = entries.first(where: { $0.comment_id == commentID }) else { return false }
        do {
            try await JDAPI.removeFavorite(favoriteID: entry.id)
            await refresh()
            showToast("已取消收藏")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }
}
