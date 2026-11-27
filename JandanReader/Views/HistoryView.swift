import SwiftUI

struct HistoryView: View {
    /// 历史记录不存所属频道，由外壳显式指定落地频道。
    let channel: Channel

    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: FeedRouter
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
                                    in: channel
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
}
