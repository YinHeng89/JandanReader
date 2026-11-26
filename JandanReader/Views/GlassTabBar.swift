import SwiftUI

/// 底部三板块切换：iOS 26+ 液态玻璃胶囊。
/// 选中态是一个 glassEffect 胶囊，通过 glassEffectID 在按钮间平滑融合移动；
/// iOS 17~25 回退为普通 Capsule 高亮，保证老系统可用。
struct GlassTabBar: View {
    @Binding var selected: Channel
    @Namespace private var namespace

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                glassContainer
            } else {
                plainContainer
            }
        }
        .padding(.horizontal, 24)
    }

    @available(iOS 26.0, *)
    private var glassContainer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Channel.all) { channel in
                    tabButton(for: channel, glass: true)
                }
            }
            .padding(5)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    private var plainContainer: some View {
        HStack(spacing: 6) {
            ForEach(Channel.all) { channel in
                tabButton(for: channel, glass: false)
            }
        }
        .padding(5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func tabButton(for channel: Channel, glass: Bool) -> some View {
        let active = selected == channel
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                selected = channel
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: channel.symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(channel.title)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Capsule())
            .background {
                if active {
                    Capsule().fill(Color.accentColor.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(GlassIDModifier(active: active, glass: glass, namespace: namespace))
        .accessibilityLabel(channel.title)
    }
}

/// 只在 iOS 26+ 给选中胶囊加 glassEffect + 融合 ID。
private struct GlassIDModifier: ViewModifier {
    let active: Bool
    let glass: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if glass, active, #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("tab", in: namespace)
        } else {
            content
        }
    }
}
