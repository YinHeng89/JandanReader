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
}

final class SettingsViewState: ObservableObject {
    @Published var clearingCache = false
    @Published var cacheCleared = false
}
