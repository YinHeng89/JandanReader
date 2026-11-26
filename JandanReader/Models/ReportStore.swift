import Foundation

/// 举报去重记录。服务端举报接口游客可调用且没有幂等校验，
/// 客户端自己记住已提交的评论，避免重复举报。
@MainActor
final class ReportStore: ObservableObject {
    static let shared = ReportStore()

    private let storageKey = "jandan:reported_comments"
    private let defaults: UserDefaults

    @Published private(set) var ids: Set<Int>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = Set(defaults.array(forKey: storageKey) as? [Int] ?? [])
    }

    func isReported(_ commentID: Int) -> Bool { ids.contains(commentID) }

    func mark(_ commentID: Int) {
        ids.insert(commentID)
        defaults.set(Array(ids), forKey: storageKey)
    }
}

/// 举报弹窗状态。Xcode 27 在 View 计算属性里操作 @State 有限制，统一用 ObservableObject。
final class ReportUIState: ObservableObject {
    @Published var showReport = false
}
