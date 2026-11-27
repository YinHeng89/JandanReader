import SwiftUI

/// 首页时间线：对齐站点官方布局——
/// 日期分组标题 + 左侧大号吐槽数 + 右侧标题/摘要 + 吐槽预览（头像·昵称·内容）。
struct HomeFeedView: View {
    @ObservedObject var store: FeedStore
    @EnvironmentObject private var banned: BannedStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sentinel = LoadMoreSentinel()

    /// 旧实现用 lastIndex(where:) 每条回扫，n 条数据 O(n²)；
    /// 改成一次线性扫描 + 日期索引表，且不要求日期连续，避免同日分段重 id。
    private var sections: [(date: String, items: [JDFeedItem])] {
        var result: [(String, [JDFeedItem])] = []
        var indexByDate: [String: Int] = [:]
        for item in store.items where !banned.isBlocked(userID: item.authorID, nickname: item.author) {
            let key = item.sectionDate ?? ""
            if let index = indexByDate[key] {
                result[index].1.append(item)
            } else {
                indexByDate[key] = result.count
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
        .task {
            await store.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { await store.checkForNewContent() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.checkForNewContent() }
            }
        }
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
        .overlay(alignment: .top) {
            if store.hasNewContent {
                NewContentBanner { Task { await store.acceptNewContent() } }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: store.hasNewContent)
            }
        }
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
                if let message = store.errorMessage {
                    VStack(spacing: 4) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("重试") { triggerLoadMore() }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // 空闲时不显示转圈；只有真正在请求时才转。
                    // 保留 16pt 透明触发区，确保哨兵的 onAppear 可靠触发。
                    Color.clear.frame(height: 16)
                }
            } else {
                Text("已经到底了").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: handleTriggerAppear)
        .onDisappear(perform: handleTriggerDisappear)
        // cursor / isLoadingMore / isLoading 任一变化都补一次调度：
        // 整页去重后 items.count 不变，只靠它会导致分页永久停摆。
        .onChange(of: store.items.count) { _, _ in handleItemsCountChange() }
        .onChange(of: store.cursor) { _, _ in handleItemsCountChange() }
        .onChange(of: store.isLoadingMore) { _, loading in
            if !loading { handleItemsCountChange() }
        }
        .onChange(of: store.isLoading) { _, loading in
            if !loading { handleItemsCountChange() }
        }
    }

    private func handleTriggerAppear() {
        sentinel.visible = true
        scheduleLoadMore()
    }

    private func handleTriggerDisappear() {
        sentinel.visible = false
        sentinel.pendingLoad?.cancel()
        sentinel.pendingLoad = nil
    }

    private func handleItemsCountChange() {
        guard sentinel.visible, store.errorMessage == nil else { return }
        scheduleLoadMore()
    }

    /// 哨兵出现后延迟一拍再翻页，避免置顶动画期间连锁追加内容把滚动位置冲掉。
    private func scheduleLoadMore() {
        guard store.errorMessage == nil else { return }
        sentinel.pendingLoad?.cancel()
        sentinel.pendingLoad = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, sentinel.visible, store.errorMessage == nil else { return }
            triggerLoadMore()
        }
    }

    private func triggerLoadMore() {
        guard store.cursor != nil, !store.isLoadingMore, !store.isLoading else { return }
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

/// 首页单行：左侧大号评论数 + 右侧标题 / 摘要 / 吐槽预览（不显示图片）。
private struct HomeRow: View {
    let item: JDFeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 评论数保持最初的大号数字，文章文字维持原字号。
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
                        // 行数固定为 3；图片开关不再顺带改变文字排版。
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let nickname = item.tucaoNickname, !nickname.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        if let url = JDAPI.avatarURL(item.tucaoAvatar) {
                            CachedAsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
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
        if let d = JDDateFormatters.sectionInput.date(from: self) {
            return JDDateFormatters.sectionOutput.string(from: d)
        }
        let parts = prefix(10).split(separator: "-")
        if parts.count == 3 { return "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日" }
        return self
    }
}
