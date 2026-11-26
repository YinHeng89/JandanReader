import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "还没有阅读记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("打开任意内容后会自动记录在这里")
                    )
                } else {
                    List {
                        ForEach(history.items) { item in
                            Button {
                                router.openArticle(
                                    id: item.postID,
                                    title: item.title,
                                    kind: item.kind,
                                    in: currentChannel
                                )
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    Text(item.date, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("阅读历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !history.items.isEmpty {
                        Button("清空", role: .destructive) { history.clear() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 历史记录只存内容类型、不存所属频道；详情页路由与频道无关，
    /// 统一落到当前频道，避免女装频道的评论历史被强行切到无聊图。
    private var currentChannel: Channel {
        Channel.withID(settings.lastChannelID)
    }
}
