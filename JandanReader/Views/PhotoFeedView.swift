import SwiftUI

/// 无聊图 / 女装频道：对齐站点官方图片流布局——
/// 每条 = 用户行（点进详情） / 正文文字 / 完整图片（GIF 播放、长按分享） / 评论数（行内展开）。
struct PhotoFeedView: View {
    @ObservedObject var store: FeedStore
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sentinel = LoadMoreSentinel()

    private var visibleItems: [JDFeedItem] {
        store.items.filter { !banned.isBlocked(userID: $0.authorID, nickname: $0.author) }
    }

    var body: some View {
        Group {
            if store.isLoading && store.items.isEmpty {
                ProgressView("正在加载 \(store.channel.title)…").tint(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = store.errorMessage, store.items.isEmpty {
                errorView(message)
            } else {
                list
            }
        }
        .toast(message: Binding(
            get: { store.toastMessage },
            set: { store.toastMessage = $0 }
        ))
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
        .toast(message: Binding(
            get: { FavoriteStore.shared.toastMessage },
            set: { FavoriteStore.shared.toastMessage = $0 }
        ))
    }

    private var list: some View {
        // 一次算好可见列表，避免 ForEach 与 prefetch 各跑一遍 filter。
        let items = visibleItems
        return List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // 评论区是当前条下面的独立 row：只在下方插入内容，不做任何 scrollTo，
                // 列表 contentOffset 保持不变，所以页面不会跳、只往下展开。
                Group {
                    PhotoRow(
                        item: item,
                        expanded: store.expandedCommentID == item.id,
                        onOpen: { store.push(.feed(item)) },
                        onComments: {
                            // 插入评论行会让下面的行高变化，短暂延迟翻页避免连锁追加；
                            // 这里不滚动列表，评论区只从当前位置往下展开。
                            sentinel.suppressUntil = Date().addingTimeInterval(0.6)
                            store.toggleInlineComments(for: item)
                        },
                        onVote: { like in
                            Task { await store.vote(item: item, like: like) }
                        },
                        voteKind: store.voteKind(item.id),
                        onProfile: item.authorID.map { id in
                            { store.push(.user(id, item.author)) }
                        },
                        onNotice: { store.showToast($0) }
                    )
                    .id(item.id)
                    // 自带分隔线会随行高变化移动/改变缩进，用行内固定分隔线代替。
                    .listRowSeparator(.hidden)
                    .onAppear { prefetchIfNeeded(index: index, count: items.count) }

                    if store.expandedCommentID == item.id {
                        InlineCommentsView(item: item, store: store)
                            .listRowSeparator(.hidden)
                    }
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

    /// 距离底部还有 4 条时就开始取下一页，滚动时不再等网。
    private func prefetchIfNeeded(index: Int, count: Int) {
        // 评论展开时行高变化会让相邻行的 onAppear 重新触发，避免误触发翻页导致列表跳动。
        // 这是提前量优化，被抑制时仍由底部哨兵负责翻页，不会卡死分页。
        guard store.expandedCommentID == nil else { return }
        guard index >= count - 4 else { return }
        triggerLoadMore()
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
                    // 空闲时不显示转圈：旧实现这里常驻 ProgressView，
                    // 刷新后一旦哨兵没被重新调度，看起来就是「一直在转圈」。
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
        // 任一分页状态变化都补一次调度：整页去重时 items.count 不变，
        // 只靠它就再也不会触发下一页。
        .onChange(of: store.items.count) { _, _ in handleItemsCountChange() }
        .onChange(of: store.cursor) { _, _ in handleItemsCountChange() }
        .onChange(of: store.isLoadingMore) { _, loading in
            if !loading { handleItemsCountChange() }
        }
        .onChange(of: store.isLoading) { _, loading in
            // 刷新期间被 store 守卫吞掉的翻页，刷新结束后补回来。
            if !loading { handleItemsCountChange() }
        }
        .onChange(of: store.expandedCommentID) { _, _ in
            if sentinel.visible { scheduleLoadMore() }
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

    /// 哨兵出现后延迟一拍再翻页，避免行高变化 / 展开评论时连锁追加内容。
    private func scheduleLoadMore() {
        guard store.errorMessage == nil else { return }
        sentinel.pendingLoad?.cancel()
        // 展开 / 收起评论后的短时间内用更长延迟；只是延迟，不会永久阻塞分页。
        let delay = max(350, Int(sentinel.suppressUntil.timeIntervalSinceNow * 1000))
        sentinel.pendingLoad = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, sentinel.visible, store.errorMessage == nil else { return }
            triggerLoadMore()
        }
    }

    private func triggerLoadMore() {
        guard store.cursor != nil, !store.isLoadingMore, !store.isLoading else { return }
        // 不再用 expandedCommentID 硬挡：展开评论只影响下方行高，顶部 contentOffset
        // 不变，翻页不会把页面顶走，更不会在展开状态下永久卡住分页。
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

/// 单条图片内容：作者元信息 / 正文大图 / 互动数据。
private struct PhotoRow: View {
    let item: JDFeedItem
    let expanded: Bool
    let onOpen: () -> Void
    let onComments: () -> Void
    let onVote: (Bool) -> Void
    /// 当前用户的投票方向：true=赞，false=踩，nil=未投。
    let voteKind: Bool?
    let onProfile: (() -> Void)?
    let onNotice: (String) -> Void
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var share = ShareState()
    @StateObject private var reportUI = ReportUIState()

    /// 原始 URL 交给图片组件：GIF 会自动换到可播放的 large 版本。
    private var images: [URL] {
        JDHTML.imageURLs(in: item.body)
    }
    private var text: String { JDHTML.plain(item.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content

            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    Button { onVote(true) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                            Text("\(item.positive)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(voteKind != nil)
                    .foregroundStyle(voteKind == true ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("feed-up-\(item.id)")
                    Button { onVote(false) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsdown")
                            Text("\(item.negative)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(voteKind != nil)
                    .foregroundStyle(voteKind == false ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("feed-down-\(item.id)")
                    Button(action: onComments) {
                        Label("\(item.commentCount)", systemImage: "bubble.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(expanded ? Color.accentColor : Color(.secondaryLabel))
                    .accessibilityLabel("评论 \(item.commentCount) 条，点击\(expanded ? "收起" : "展开")")
                }
                .font(.system(size: 12))

                // 位置与长度固定的分隔线，展开评论时不会被顶走。
                Divider()
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            if let url = images.first {
                Button {
                    Task { await share.prepareOriginal(from: url) }
                } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                }
            }
            Button(action: onOpen) {
                Label("查看详情", systemImage: "doc.text")
            }
            if !item.author.isEmpty {
                Button(role: .destructive) {
                    banned.block(userID: item.authorID, nickname: item.author)
                } label: {
                    Label("屏蔽用户", systemImage: "hand.raised.slash")
                }
            }
            if ReportStore.shared.isReported(item.id) {
                Text("已举报")
            } else {
                Button {
                    reportUI.showReport = true
                } label: {
                    Label("举报", systemImage: "flag")
                }
            }
            Button { toggleFavorite() } label: {
                Label(
                    FavoriteStore.shared.isFavorite(item.id) ? "取消收藏" : "收藏",
                    systemImage: FavoriteStore.shared.isFavorite(item.id) ? "bookmark.fill" : "bookmark"
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { share.item != nil },
            set: { if !$0 { share.item = nil } }
        )) {
            if let item = share.item {
                ShareSheet(activityItems: [item])
            }
        }
        .confirmationDialog("举报原因", isPresented: $reportUI.showReport) {
            Button("违法违规") { submitReport(type: 1, reason: "违法违规") }
            Button("色情低俗") { submitReport(type: 2, reason: "色情低俗") }
            Button("引战 / 人身攻击") { submitReport(type: 3, reason: "引战人身攻击") }
            Button("取消", role: .cancel) {}
        }
    }

    private func submitReport(type: Int, reason: String) {
        Task {
            do {
                try await JDAPI.report(commentID: item.id, reason: reason, type: type)
                ReportStore.shared.mark(item.id)
                onNotice("举报已提交")
            } catch {
                onNotice(error.localizedDescription)
            }
        }
    }

    private func toggleFavorite() {
        guard auth.isLoggedIn else {
            onNotice("请先登录煎蛋账号")
            return
        }
        Task {
            if FavoriteStore.shared.isFavorite(item.id) {
                await FavoriteStore.shared.remove(commentID: item.id)
            } else {
                await FavoriteStore.shared.add(commentID: item.id)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 昵称进个人主页，日期 / 编号进详情；图片完整显示，长按分享。
            HStack(spacing: 6) {
                Button { onProfile?() } label: {
                    HStack(spacing: 6) {
                        if let url = JDAPI.avatarURL(item.avatar) {
                            CachedAsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            }
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                        }
                        Text(item.author.isEmpty ? "匿名" : item.author)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(onProfile == nil)
                .accessibilityLabel("查看作者主页")

                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Text(item.date.jdShortDate)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("#\(item.id)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开详情")
            }

            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14 * settings.fontScale / 100))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !images.isEmpty {
                VStack(spacing: 8) {
                    ForEach(images, id: \.absoluteString) { url in
                        InlineAnimatedImageView(url: url)
                    }
                }
            }
        }
    }
}

/// 行内吐槽区：首次展开才请求 /api/tucao/list/{评论ID}。
private struct InlineCommentsView: View {
    let item: JDFeedItem
    @ObservedObject var store: FeedStore
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var compose = ComposeState()

    private var loaded: [JDComment]? {
        store.inlineComments[item.id]?.filter {
            !banned.isBlocked(userID: $0.user_id, nickname: $0.author)
        }
    }
    private var isLoading: Bool { store.inlineLoadingIDs.contains(item.id) }
    private var message: String? { store.inlineErrors[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading && loaded == nil {
                HStack(spacing: 6) {
                    ProgressView().tint(Color.accentColor)
                    Text("评论加载中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let message {
                HStack(spacing: 8) {
                    Text("评论加载失败：\(message)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("重试") { Task { await store.loadInlineComments(for: item) } }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            } else if let loaded, !loaded.isEmpty {
                Text("评论 · \(loaded.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(loaded) { comment in
                    InlineCommentRow(
                        comment: comment,
                        onVote: { like in
                            Task {
                                await store.voteInline(
                                    itemID: item.id, commentID: comment.id, like: like
                                )
                            }
                        },
                        voteKind: store.voteKind(comment.id),
                        onProfile: comment.user_id.map { id in
                            { store.push(.user(id, comment.author ?? "")) }
                        }
                    )
                }
            } else {
                Text("暂无评论")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            composeBar
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var composeBar: some View {
        HStack(spacing: 8) {
            TextField("发表吐槽…", text: $compose.draft)
                .textFieldStyle(.roundedBorder)
                .disabled(compose.isSending)
                .onSubmit { Keyboard.dismiss() }
            Button {
                Task { await submit() }
            } label: {
                if compose.isSending {
                    ProgressView().tint(.white)
                } else {
                    Text("发送")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                compose.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || compose.isSending
            )
        }
        .dismissKeyboardToolbar()
    }

    private func submit() async {
        guard auth.isLoggedIn else {
            Keyboard.dismiss()
            store.showToast("请先登录煎蛋账号")
            return
        }
        compose.isSending = true
        defer { compose.isSending = false }
        let ok = await store.submitInline(
            itemID: item.id, commentID: item.id,
            content: compose.draft, author: auth.user?.nickname ?? "匿名"
        )
        if ok {
            compose.draft = ""
            Keyboard.dismiss()
        }
    }
}

/// 行内吐槽行：与详情页评论行同布局——作者 / 地区 / 日期 / 点赞同一行，正文在下。
private struct InlineCommentRow: View {
    let comment: JDComment
    let onVote: (Bool) -> Void
    let voteKind: Bool?
    let onProfile: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if let url = JDAPI.avatarURL(comment.avatar_ref) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                Button { onProfile?() } label: {
                    Text(comment.author ?? "匿名")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(onProfile == nil)
                if comment.id < 0 {
                    Text("待审核")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let location = comment.ip_location, !location.isEmpty {
                    Text(location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let date = comment.date_gmt {
                    Text(date.jdShortDate).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    Button { onVote(true) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                            Text("\(comment.vote_positive ?? 0)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(voteKind != nil)
                    .foregroundStyle(voteKind == true ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("inline-up-\(comment.id)")
                    Button { onVote(false) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsdown")
                            Text("\(comment.vote_negative ?? 0)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(voteKind != nil)
                    .foregroundStyle(voteKind == false ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("inline-down-\(comment.id)")
                }
                .font(.caption2.weight(.semibold))
            }
            RichText(html: comment.content ?? "", baseFont: 0.85)
        }
        .padding(.vertical, 10)
    }
}
