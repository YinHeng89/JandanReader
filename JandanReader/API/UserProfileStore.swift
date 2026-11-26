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
    /// 带时间戳，超过 TTL / 容量上限自动淘汰，避免长期驻留内存。
    private struct Cached {
        let profile: JDUserProfile?
        let badges: [JDBadge]
        let comments: [JDComment]
        let tucaos: [JDComment]
        let at: Date
    }

    private static var cache: [Int: Cached] = [:]
    private static let cacheTTL: TimeInterval = 300
    private static let cacheLimit = 40

    init(userID: Int) {
        self.userID = userID
        if let cached = Self.cache[userID],
           Date().timeIntervalSince(cached.at) < Self.cacheTTL {
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
        let now = Date()
        Self.cache = Self.cache.filter { now.timeIntervalSince($0.value.at) < Self.cacheTTL }
        if Self.cache.count >= Self.cacheLimit,
           let oldest = Self.cache.min(by: { $0.value.at < $1.value.at })?.key {
            Self.cache.removeValue(forKey: oldest)
        }
        Self.cache[userID] = Cached(
            profile: profile, badges: badges, comments: comments, tucaos: tucaos, at: now
        )
        isLoading = false
    }
}
