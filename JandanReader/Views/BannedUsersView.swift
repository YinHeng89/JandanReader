import SwiftUI

/// 屏蔽管理：每个用户一条（昵称优先），可查看 id 并解除。
struct BannedUsersView: View {
    @EnvironmentObject private var banned: BannedStore

    var body: some View {
        List {
            if banned.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("还没有屏蔽任何用户")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("在图片流或详情页长按作者昵称即可屏蔽")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(banned.entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(.system(size: 14))
                            if let id = entry.userID {
                                Text("ID \(id)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("解除") { banned.remove(entry) }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("屏蔽的用户")
        .navigationBarTitleDisplayMode(.inline)
    }
}
