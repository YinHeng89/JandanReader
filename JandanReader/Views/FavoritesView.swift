import SwiftUI

/// 我的收藏：需登录，列表来自 /api/member/comment/favorites。
struct FavoritesView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = FavoriteStore.shared
    @StateObject private var ui = FavoritesUIState()

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    Text("请先登录煎蛋账号")
                        .font(.headline)
                    Text("收藏内容需要登录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoading && store.entries.isEmpty {
                ProgressView("加载中…").tint(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    Text("还没有收藏内容")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard auth.isLoggedIn else { return }
            await store.refresh()
        }
        .toast(message: Binding(
            get: { store.toastMessage },
            set: { store.toastMessage = $0 }
        ))
        .confirmationDialog(
            "删除收藏",
            isPresented: Binding(
                get: { ui.pendingDeleteID != nil },
                set: { if !$0 { ui.pendingDeleteID = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let id = ui.pendingDeleteID {
                    Task { await store.remove(commentID: id) }
                }
                ui.pendingDeleteID = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var list: some View {
        List {
            ForEach(store.entries, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("#\(entry.comment_id ?? 0)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(entry.comment_author ?? "匿名")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        if let date = entry.comment_date {
                            Text(date.jdShortDate)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if let title = entry.post_title, !title.isEmpty {
                        Text("@\(title)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(JDHTML.plain(entry.comment_content ?? ""))
                        .font(.system(size: 13 * settings.fontScale / 100))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { open(entry) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        ui.pendingDeleteID = entry.comment_id ?? 0
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }

    private func open(_ entry: JDFavorite) {
        guard let id = entry.comment_id else { return }
        router.openArticle(
            id: id,
            title: entry.post_title ?? "详情",
            kind: "comment",
            in: Channel.withID(settings.lastChannelID)
        )
    }
}

final class FavoritesUIState: ObservableObject {
    @Published var pendingDeleteID: Int?
}
