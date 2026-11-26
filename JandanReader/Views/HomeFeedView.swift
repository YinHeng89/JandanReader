import SwiftUI

/// 首页时间线：对齐站点官方布局——
/// 日期分组标题 + 左侧大号吐槽数 + 右侧标题/摘要 + 吐槽预览（头像·昵称·内容）。
struct HomeFeedView: View {
    @ObservedObject var store: FeedStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var banned: BannedStore
    @StateObject private var sentinel = LoadMoreSentinel()

    private var sections: [(date: String, items: [JDFeedItem])] {
        var result: [(String, [JDFeedItem])] = []
        for item in store.items where !banned.isBlocked(userID: item.authorID, nickname: item.author) {
            let key = item.sectionDate ?? ""
            if let last = result.lastIndex(where: { $0.0 == key }) {
                result[last].1.append(item)
            } else {
                result.append((key, [item]))
            }
        }
        return result.map { (date: $0.0, items: $0.1) }
    }

    var body: some View {
        Group {
            if store.isLoading && store.items.isEmpty {
                ProgressView("正在加载新鲜事…").tint(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = store.errorMessage, store.items.isEmpty {
                errorView(message)
            } else {
                list
            }
        }
        .task { await store.load() }
    }

    private var list: some View {
        List {
            ForEach(sections, id: \.date) { section in
                Section {
                    ForEach(section.items) { item in
                        Button { store.push(.feed(item)) } label: {
                            HomeRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let nickname = item.tucaoNickname, !nickname.isEmpty {
                                Button(role: .destructive) {
                                    banned.block(userID: nil, nickname: nickname)
                                } label: {
                                    Label("屏蔽用户", systemImage: "hand.raised.slash")
                                }
                            }
                        }
                    }
                } header: {
                    // Plain List 的 Section header 原生吸顶；压缩字号与边距，避免顶部过高。
                    Text(section.date.jdSectionDate)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
            }
            loadMoreSection
        }
        .listStyle(.plain)
        .refreshable { await store.reload() }
    }

    @ViewBuilder
    private var loadMoreSection: some View {
        if !store.items.isEmpty {
            Section {
                loadTrigger
            }
        }
    }

    /// 滚动到底部时自动翻页，不需要点按钮。
    @ViewBuilder
    private var loadTrigger: some View {
        Group {
            if store.isLoadingMore {
                HStack { Spacer(); ProgressView().tint(Color.accentColor); Spacer() }
            } else if store.cursor != nil {
                if store.errorMessage != nil {
                    VStack(spacing: 4) {
                        Text("加载失败，上滑重试").font(.caption).foregroundStyle(.secondary)
                        Button("重试") { triggerLoadMore() }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack { Spacer(); ProgressView().tint(Color.accentColor); Spacer() }
                }
            } else {
                Text("已经到底了").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: handleTriggerAppear)
        .onDisappear(perform: handleTriggerDisappear)
        .onChange(of: store.items.count) { _, _ in handleItemsCountChange() }
    }

    private func handleTriggerAppear() {
        sentinel.visible = true
        triggerLoadMore()
    }

    private func handleTriggerDisappear() { sentinel.visible = false }

    private func handleItemsCountChange() {
        // 新一页不足一屏时 sentinel 不会重新出现，数据变化后补一次触发。
        if sentinel.visible { triggerLoadMore() }
    }

    private func triggerLoadMore() {
        guard store.cursor != nil, !store.isLoadingMore else { return }
        Task { await store.loadMore() }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Color.accentColor)
            Text("加载失败").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("重试") { Task { await store.reload() } }
                .buttonStyle(.borderedProminent).tint(Color.accentColor)
        }
    }
}

/// 首页单行：左侧大号分数 + 右侧标题 / 摘要 / 吐槽预览。
private struct HomeRow: View {
    let item: JDFeedItem
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(item.score)")
                .font(.system(size: 34, weight: .light, design: .rounded))
                .foregroundStyle(Color(.tertiaryLabel))
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(settings.cleanMode ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let nickname = item.tucaoNickname, !nickname.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        if let avatar = item.tucaoAvatar, let url = URL(string: avatar) {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color(.secondarySystemBackground)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        }
                        Text("\(nickname): \(item.tucaoContent ?? "")")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

extension String {
    /// "2026-11-26T10:06:55+08:00" → "11月26日"
    var jdSectionDate: String {
        let date = self
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let d = formatter.date(from: date) {
            let out = DateFormatter()
            out.dateFormat = "M月d日"
            out.locale = Locale(identifier: "zh_CN")
            return out.string(from: d)
        }
        let parts = date.prefix(10).split(separator: "-")
        if parts.count == 3 { return "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日" }
        return date
    }
}
