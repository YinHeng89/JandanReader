import Foundation
import SwiftUI

/// 一条屏蔽记录：同一个人只有一条，同时记住 id 与昵称（各自都可能缺失）。
struct BannedEntry: Identifiable, Hashable, Codable {
    let userID: Int?
    let nickname: String?

    var id: String {
        if let userID { return "id:\(userID)" }
        if let nickname, !nickname.isEmpty { return "nick:\(nickname)" }
        return "unknown"
    }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let userID { return "用户 ID \(userID)" }
        return "未知用户"
    }
}

/// 本地作者黑名单。对齐官方 App / web 端：按 user_id 与昵称过滤，
/// 不依赖登录态，也不请求服务端封禁接口。
@MainActor
final class BannedStore: ObservableObject {
    private enum Key {
        static let entries = "jd_banned_entries"
        /// 旧版把 id / 昵称分开存，升级时迁移成合并记录。
        static let legacyIDs = "jd_banned_user_ids"
        static let legacyNicks = "jd_banned_nicks"
    }

    private let defaults = UserDefaults.standard

    @Published private(set) var entries: [BannedEntry]

    init() {
        if let data = defaults.data(forKey: Key.entries),
           let decoded = try? JSONDecoder().decode([BannedEntry].self, from: data) {
            entries = decoded
        } else {
            // 旧数据：id 与昵称各自一条，能配对的合并成一条。
            let ids = defaults.stringArray(forKey: Key.legacyIDs) ?? []
            let nicks = defaults.stringArray(forKey: Key.legacyNicks) ?? []
            var result: [BannedEntry] = []
            // 旧数据里 id 与昵称没有对应关系，各自成条。
            for idText in ids {
                result.append(BannedEntry(userID: Int(idText), nickname: nil))
            }
            for nick in nicks where !result.contains(where: { $0.nickname == nick }) {
                result.append(BannedEntry(userID: nil, nickname: nick))
            }
            entries = result
            persist()
        }
    }

    /// user_id 优先、昵称兜底，任一命中即视为已屏蔽。
    func isBlocked(userID: Int?, nickname: String?) -> Bool {
        entries.contains { entry in
            if let userID, entry.userID == userID { return true }
            if let nickname, !nickname.isEmpty, entry.nickname == nickname { return true }
            return false
        }
    }

    /// 同一个人只保留一条：先按 id 找，再按昵称找，找到就补全另一字段。
    func block(userID: Int?, nickname: String?) {
        if let index = entries.firstIndex(where: { entry in
            if let userID, entry.userID == userID { return true }
            if let nickname, !nickname.isEmpty, entry.nickname == nickname { return true }
            return false
        }) {
            let old = entries[index]
            entries[index] = BannedEntry(
                userID: old.userID ?? userID,
                nickname: old.nickname ?? (nickname?.isEmpty == true ? nil : nickname)
            )
        } else {
            entries.append(BannedEntry(
                userID: userID,
                nickname: nickname?.isEmpty == true ? nil : nickname
            ))
        }
        persist()
    }

    func remove(_ entry: BannedEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Key.entries)
        PrefsStore.shared.notifyLocalChange()
    }
}
