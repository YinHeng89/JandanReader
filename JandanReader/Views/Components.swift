import SwiftUI

/// 列表底部哨兵的可见状态。Xcode 27 下 View 内 @State 赋值受限，
/// 用 @StateObject 持有引用类型来记录“是否已滚到底部”。
final class LoadMoreSentinel: ObservableObject {
    var visible = false
}

struct IconButton: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .contentShape(Circle())
            .accessibilityLabel(systemName)
    }
}
