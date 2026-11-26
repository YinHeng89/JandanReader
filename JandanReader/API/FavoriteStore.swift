import Foundation
import SwiftUI

/// 收藏状态：只拉第一页（最近 20 条）用于菜单判断和列表展示。
/// 服务端没有批量「是否已收藏」接口，照官方做法以本地 ID 集合为准。
@MainActor
final class FavoriteStore: ObservableObject {
    static let shared = FavoriteStore()

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
        do {
            let page = try await JDAPI.favorites(page: 1)
            entries = page.list ?? []
            commentIDs = Set(entries.compactMap(\.comment_id))
        } catch {
            // 后台刷新失败保持静默，不打断当前页面
        }
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
