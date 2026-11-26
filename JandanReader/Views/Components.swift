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

/// 轻量提示：底部胶囊，2 秒自动消失，不打断当前页面。
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: message)
            }
        }
    }
}

extension View {
    func toast(message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
