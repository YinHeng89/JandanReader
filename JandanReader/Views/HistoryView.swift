import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    let onOpen: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "还没有阅读记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("打开任意文章后会自动记录在这里")
                    )
                } else {
                    List {
                        ForEach(history.items) { item in
                            Button {
                                guard let url = URL(string: item.url) else { return }
                                onOpen(url)
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
