import Foundation
import SwiftUI

/// 消息通知：未读数轮询 + 分页列表 + 已读闭环。间隔与官方前端一致（3 分钟）。
@MainActor
final class NoticeStore: ObservableObject {
    static let shared = NoticeStore()

    @Published private(set) var unread = 0
    @Published private(set) var entries: [JDNotification] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published var toastMessage: String?

    private var currentPage = 1
    private var pollingTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toastMessage == message { self.toastMessage = nil }
        }
    }

    func refreshUnread() async {
        do { unread = try await JDAPI.checkNotice() } catch { /* 静默 */ }
    }

    func load(page: Int = 1) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await JDAPI.notifications(page: page)
            let list = result.list ?? []
            entries = list
            currentPage = page
            hasMore = Self.moreAvailable(list: list, loaded: list.count, total: result.total)
            await markCurrentPageRead()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// 用户主动点「加载更多」才翻页，避免滚动到顶/底时被连锁触发。
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let next = currentPage + 1
        do {
            let result = try await JDAPI.notifications(page: next)
            let list = result.list ?? []
            let existing = Set(entries.map(\.id))
            entries += list.filter { !existing.contains($0.id) }
            currentPage = next
            hasMore = Self.moreAvailable(list: list, loaded: entries.count, total: result.total)
            await markCurrentPageRead()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private static func moreAvailable(list: [JDNotification], loaded: Int, total: Int?) -> Bool {
        guard !list.isEmpty else { return false }
        if let total, loaded >= total { return false }
        return true
    }

    /// 与官方一致：打开消息列表即把当前页标记已读。
    private func markCurrentPageRead() async {
        let ids = entries.filter { !$0.isRead }.map(\.id)
        guard !ids.isEmpty else { return }
        try? await JDAPI.readNotices(ids: ids)
        await refreshUnread()
    }

    func clear() async {
        do {
            try await JDAPI.clearNotices()
            await load()
            showToast("已全部标记已读")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func startPolling() {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                await refreshUnread()
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func reset() {
        unread = 0
        entries = []
        hasMore = false
        currentPage = 1
    }
}
