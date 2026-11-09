import SwiftUI

struct IconButton: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .contentShape(Circle())
    }
}

struct ToolButton: View {
    let systemName: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct ChannelBar: View {
    @Binding var selected: Channel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Channel.all) { channel in
                    let active = selected == channel
                    Button {
                        selected = channel
                    } label: {
                        Label(channel.title, systemImage: channel.symbol)
                            .font(.system(size: 13, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(active ? Color.accentColor : Color(.secondarySystemBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }
}

struct ProgressLine: View {
    let progress: Double
    let isLoading: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.clear
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    .opacity(isLoading ? 1 : 0)
            }
        }
        .frame(height: 2)
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}
