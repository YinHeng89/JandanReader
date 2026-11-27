import SwiftUI

/// 消息通知中心：需登录，打开列表即标记当前页已读。
struct NotificationsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = NoticeStore.shared

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    Text("请先登录煎蛋账号")
                        .font(.headline)
                    Text("消息通知需要登录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoading && store.entries.isEmpty {
                ProgressView("加载中…").tint(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    Text("暂无消息")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("消息通知")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") { Task { await store.clear() } }
                    .disabled(store.entries.isEmpty)
            }
        }
        .task {
            guard auth.isLoggedIn else { return }
            await store.load()
        }
        .toast(message: Binding(
            get: { store.toastMessage },
            set: { store.toastMessage = $0 }
        ))
    }

    private var list: some View {
        List {
            ForEach(store.entries) { notice in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !notice.isRead {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(notice.title ?? "通知")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        if let date = notice.created_at {
                            Text(date.jdShortDate)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(JDHTML.plain(notice.content ?? ""))
                        .font(.system(size: 13 * settings.fontScale / 100))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(.vertical, 4)
            }
            if store.hasMore {
                HStack {
                    Spacer()
                    if store.isLoading {
                        ProgressView().tint(Color.accentColor)
                    } else {
                        Button("加载更多") { Task { await store.loadMore() } }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.load() }
    }
}
