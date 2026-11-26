import Foundation
import SwiftUI

/// 消息通知：未读数轮询 + 列表 + 已读闭环。间隔与官方前端一致（3 分钟）。
@MainActor
final class NoticeStore: ObservableObject {
    static let shared = NoticeStore()

    @Published private(set) var unread = 0
    @Published private(set) var entries: [JDNotification] = []
    @Published private(set) var isLoading = false
    @Published var toastMessage: String?

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
            entries = result.list ?? []
            // 与官方一致：打开消息列表即把当前页标记已读。
            let ids = entries.filter { !$0.isRead }.map(\.id)
            if !ids.isEmpty {
                try? await JDAPI.readNotices(ids: ids)
                await refreshUnread()
            }
        } catch {
            showToast(error.localizedDescription)
        }
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
    }
}
