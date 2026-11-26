import Foundation
import SwiftUI

/// 作者个人页数据容器：四个公开端点并行拉取，互不拖累。
@MainActor
final class UserProfileStore: ObservableObject {
    @Published private(set) var profile: JDUserProfile?
    @Published private(set) var badges: [JDBadge] = []
    @Published private(set) var comments: [JDComment] = []
    @Published private(set) var tucaos: [JDComment] = []
    @Published private(set) var isLoading = true
    @Published var toastMessage: String?

    let userID: Int

    /// 同一用户二次进入直接复用，避免每次都等四个接口（最慢约 1s）。
    private static var cache: [Int: (profile: JDUserProfile?, badges: [JDBadge], comments: [JDComment], tucaos: [JDComment])] = [:]

    init(userID: Int) {
        self.userID = userID
        if let cached = Self.cache[userID] {
            self.profile = cached.profile
            self.badges = cached.badges
            self.comments = cached.comments
            self.tucaos = cached.tucaos
            self.isLoading = false
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toastMessage == message { self.toastMessage = nil }
        }
    }

    func load() async {
        isLoading = true
        async let p = try? JDAPI.userProfile(userID)
        async let b = try? JDAPI.userBadges(userID)
        async let c = try? JDAPI.userComments(userID)
        async let t = try? JDAPI.userTucaos(userID)
        profile = await p
        badges = await b ?? []
        comments = await c ?? []
        tucaos = await t ?? []
        Self.cache[userID] = (profile, badges, comments, tucaos)
        isLoading = false
    }
}
