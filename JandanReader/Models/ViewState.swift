import SwiftUI

/// 本地 UI 状态容器。
/// 用 ObservableObject + @Published 代替 SwiftUI 的 @State 宏：
/// 本机 Xcode 27.2 的 iPhoneOS 平台 swift-plugin-server 在展开 StateMacro 时
/// 会返回 malformed response（模拟器平台正常），改用传统 property wrapper 规避。
/// 底部 Tab 选择：三个内容频道 + 设置。
enum AppTab: Hashable {
    case channel(Channel)
    case settings
}

final class ContentViewState: ObservableObject {
    @Published var selected: AppTab = .channel(.home)
    @Published var showShare = false
    @Published var showAccount = false
    @Published var didConfigure = false
    /// 点击当前 Tab 时的精确置顶兜底（纯观察，不改变系统 TabView 行为）。
    let tabTopFix = TabTopFix()
}

final class SettingsViewState: ObservableObject {
    @Published var clearingCache = false
    @Published var cacheCleared = false
}

/// 发布输入框状态。Xcode 27 下用 ObservableObject 代替 View 内 @State。
final class ComposeState: ObservableObject {
    @Published var draft = ""
    @Published var isSending = false
}
