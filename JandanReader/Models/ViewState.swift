import SwiftUI

/// 本地 UI 状态容器。
/// 用 ObservableObject + @Published 代替 SwiftUI 的 @State 宏：
/// 本机 Xcode 27.2 的 iPhoneOS 平台 swift-plugin-server 在展开 StateMacro 时
/// 会返回 malformed response（模拟器平台正常），改用传统 property wrapper 规避。
final class ContentViewState: ObservableObject {
    @Published var selected: Channel = .home
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var showShare = false
    @Published var didConfigure = false
    /// 非 nil 时呈现用户中心独立页。
    @Published var accountURL: URL?
}

final class SettingsViewState: ObservableObject {
    @Published var clearingCache = false
    @Published var cacheCleared = false
    /// 点账户功能页时先记下目标，等 sheet 完全消失再交给外壳弹独立页，
    /// 避免 dismiss 与 fullScreenCover 同时发生导致后者被吞。
    @Published var pendingURL: URL?
}
