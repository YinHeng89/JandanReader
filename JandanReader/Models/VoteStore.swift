import Foundation

/// 全局投票状态。服务端没有「我投过哪些评论」查询接口，
/// 只能由客户端自己记录 comment_id → 方向（true=赞 / false=踩）。
/// 持久化到 UserDefaults，避免重启后重复投票被服务端拒绝。
@MainActor
final class VoteStore: ObservableObject {
    static let shared = VoteStore()

    /// 投票记录只增不减，长期会撑大 UserDefaults；超限时丢弃一半旧记录。
    private let maxEntries = 2000

    @Published private(set) var kinds: [Int: Bool]

    private let storageKey = "jandan:vote_kinds"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored: [Int: Bool] = [:]
        if let raw = defaults.dictionary(forKey: storageKey) as? [String: Bool] {
            for (key, value) in raw {
                if let id = Int(key) { restored[id] = value }
            }
        }
        self.kinds = restored
    }

    /// 投票方向：true=赞，false=踩，nil=未投票。
    func kind(_ commentID: Int) -> Bool? { kinds[commentID] }

    func isVoted(_ commentID: Int) -> Bool { kinds[commentID] != nil }

    /// 投票成功后调用；同一条只能记录一个方向。
    func set(_ commentID: Int, like: Bool) {
        if kinds[commentID] == nil, kinds.count >= maxEntries {
            let keep = Set(kinds.keys.prefix(maxEntries / 2))
            kinds = kinds.filter { keep.contains($0.key) }
        }
        kinds[commentID] = like
        let raw = Dictionary(uniqueKeysWithValues: kinds.map { ("\($0.key)", $0.value) })
        defaults.set(raw, forKey: storageKey)
    }
}
