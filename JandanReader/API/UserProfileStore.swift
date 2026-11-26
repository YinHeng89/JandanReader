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

    init(userID: Int) { self.userID = userID }

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
        isLoading = false
    }
}
