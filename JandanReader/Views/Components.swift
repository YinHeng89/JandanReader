import SwiftUI

/// 列表底部哨兵的可见状态。Xcode 27 下 View 内 @State 赋值受限，
/// 用 @StateObject 持有引用类型来记录“是否已滚到底部”。
final class LoadMoreSentinel: ObservableObject {
    var visible = false
    /// 哨兵触发翻页的去抖任务：行高变化或展开评论会让哨兵短暂进入视口，
    /// 立刻请求会在置顶 / 展开动画期间改变内容高度，把滚动位置冲掉。
    var pendingLoad: Task<Void, Never>?
    /// 展开 / 收起评论时只把翻页**延迟**一小段时间，避免连锁追加；
    /// 这不是永久开关，超时后仍会正常翻页（旧实现用 expandedCommentID 硬挡，会卡死分页）。
    var suppressUntil: Date = .distantPast
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

    /// 输入框键盘上方加「完成」按钮，保证任何情况下都能手动收起键盘。
    func dismissKeyboardToolbar() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { Keyboard.dismiss() }
            }
        }
    }
}

/// 统一收起键盘（SwiftUI 没有可靠的 FocusState 跨页面收起方式）。
enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

/// 「有新内容」浮层：顶部胶囊，点击后刷新，不自动打断阅读。
struct NewContentBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                Text("有新内容")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("有新内容，点击刷新")
    }
}
