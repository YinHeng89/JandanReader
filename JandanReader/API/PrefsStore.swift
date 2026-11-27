import Foundation
import SwiftUI

/// VIP 偏好云同步。membership 是位掩码，4 = Subscription。
/// 策略：本地优先合并——下拉时补齐云端条目但绝不删除本地数据，
/// 合并结果再回传，避免多设备间互相覆盖。
@MainActor
final class PrefsStore: ObservableObject {
    static let shared = PrefsStore()

    @Published private(set) var isSynced = false
    @Published private(set) var lastSyncedAt: Date?
    @Published var toastMessage: String?

    private weak var settings: AppSettings?
    private weak var banned: BannedStore?
    private weak var auth: AuthStore?
    private var pushTask: Task<Void, Never>?
    private(set) var applyingRemote = false

    func configure(settings: AppSettings, banned: BannedStore, auth: AuthStore) {
        self.settings = settings
        self.banned = banned
        self.auth = auth
    }

    var canSync: Bool {
        guard let auth, auth.isLoggedIn, let membership = auth.user?.membership else { return false }
        return (membership & 4) != 0
    }

    /// 本地设置 / 黑名单变化入口；应用远端数据时跳过，避免回环。
    func notifyLocalChange() {
        guard !applyingRemote else { return }
        schedulePush()
    }

    func schedulePush() {
        guard canSync else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await push()
        }
    }

    /// 拉取云端偏好并合并到本地，再把合并结果回传。
    func pull() async {
        guard canSync else { return }
        do {
            guard let prefs = try await JDAPI.getPrefs() else { return }
            applyingRemote = true
            defer { applyingRemote = false }

            if let remote = prefs["settings"] as? [String: Any], let settings {
                // 云端字段名沿用旧版 cleanMode，保证跨版本 / 跨设备兼容。
                if let value = remote["cleanMode"] as? Bool { settings.useThumbnails = value }
                if let value = remote["darkMode"] as? Bool { settings.darkMode = value }
                if let value = remote["fontScale"] as? Double { settings.fontScale = value }
                else if let value = remote["fontScale"] as? Int { settings.fontScale = Double(value) }
            }
            if let banned {
                if let ids = prefs["block_ids"] as? [String: Any] {
                    for key in ids.keys {
                        if let id = Int(key) { banned.block(userID: id, nickname: nil) }
                    }
                }
                if let nicks = prefs["block_nicks"] as? [String: Any] {
                    for key in nicks.keys where !key.isEmpty {
                        banned.block(userID: nil, nickname: key)
                    }
                }
            }
            await push()
        } catch {
            isSynced = false
        }
    }

    func push() async {
        guard canSync, let settings, let banned else { return }
        var ids: [String: Any] = [:]
        var nicks: [String: Any] = [:]
        let timestamp = Int(Date().timeIntervalSince1970)
        for entry in banned.entries {
            if let userID = entry.userID {
                ids["\(userID)"] = ["nickname": entry.nickname ?? "", "at": timestamp]
            }
            if let nickname = entry.nickname, !nickname.isEmpty {
                nicks[nickname] = ["nickname": nickname, "at": timestamp]
            }
        }
        let payload: [String: Any] = [
            "settings": [
                // 云端字段名保持 cleanMode（旧版 / 站点前端约定），语义是「使用缩略图」。
                "cleanMode": settings.useThumbnails,
                "darkMode": settings.darkMode,
                "fontScale": settings.fontScale
            ],
            "block_ids": ids,
            "block_nicks": nicks
        ]
        do {
            try await JDAPI.updatePrefs(payload)
            isSynced = true
            lastSyncedAt = Date()
        } catch {
            isSynced = false
        }
    }
}
