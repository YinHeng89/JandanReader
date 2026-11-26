import SwiftUI

/// 原生详情页：正文 + 图片 + 吐槽 / 评论。
struct PostDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var store: DetailStore
    @StateObject private var compose = ComposeState()

    init(item: JDFeedItem) {
        _store = StateObject(wrappedValue: DetailStore(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.isLoading {
                    ProgressView("加载中…").tint(Color.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = store.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                        Text("加载失败").font(.headline)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("重试") { Task { await store.load() } }
                            .buttonStyle(.borderedProminent).tint(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            if !store.isLoading && store.errorMessage == nil {
                Divider()
                composeBar
            }
        }
        .navigationTitle(store.item.title.isEmpty ? "详情" : store.item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: Binding(
            get: { store.toastMessage },
            set: { store.toastMessage = $0 }
        ))
        .toast(message: Binding(
            get: { FavoriteStore.shared.toastMessage },
            set: { FavoriteStore.shared.toastMessage = $0 }
        ))
        .task { await store.load() }
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
        .padding(12)
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
        let ok = await store.submit(content: compose.draft, author: auth.user?.nickname ?? "匿名")
        if ok {
            compose.draft = ""
            Keyboard.dismiss()
        }
    }

    private var visibleComments: [JDComment] {
        store.comments.filter { !banned.isBlocked(userID: $0.user_id, nickname: $0.author) }
    }

    private var visibleTucaos: [JDComment] {
        store.tucaos.filter { !banned.isBlocked(userID: $0.user_id, nickname: $0.author) }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                bodyContent
                if !visibleComments.isEmpty {
                    Divider()
                    Text("评论 · \(visibleComments.count)").font(.headline)
                    ForEach(visibleComments) { comment in
                        CommentRow(comment: comment, voteKind: store.voteKind(comment.id), onProfile: {
                            if let uid = comment.user_id {
                                router.store(for: Channel.withID(settings.lastChannelID))?
                                    .push(.user(uid, comment.author ?? ""))
                            }
                        }, onNotice: { store.showToast($0) }) {
                            Task { await store.vote(commentID: comment.id, like: true) }
                        } onDown: {
                            Task { await store.vote(commentID: comment.id, like: false) }
                        }
                    }
                }
                if !visibleTucaos.isEmpty {
                    Divider()
                    Text("吐槽 · \(visibleTucaos.count)").font(.headline)
                    ForEach(visibleTucaos) { tucao in
                        CommentRow(comment: tucao, voteKind: store.voteKind(tucao.id), onProfile: {
                            if let uid = tucao.user_id {
                                router.store(for: Channel.withID(settings.lastChannelID))?
                                    .push(.user(uid, tucao.author ?? ""))
                            }
                        }, onNotice: { store.showToast($0) }) {
                            Task { await store.vote(commentID: tucao.id, like: true) }
                        } onDown: {
                            Task { await store.vote(commentID: tucao.id, like: false) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.item.title.isEmpty {
                Text(store.item.title)
                    .font(.system(size: 20, weight: .bold))
            }
            HStack(spacing: 8) {
                if !store.item.author.isEmpty {
                    Label(store.item.author, systemImage: "person.circle")
                }
                if !store.item.date.isEmpty {
                    Text(store.item.date.jdShortDate)
                }
                if let location = store.item.location, !location.isEmpty {
                    Text(location)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch store.content {
        case .article(let detail):
            RichText(html: detail.content ?? "", baseFont: 1)
            if !(detail.tags?.isEmpty ?? true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(detail.tags ?? []) { tag in
                            if let name = tag.name {
                                Text(name).font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
            }
        case .comment(let comment):
            RichText(html: comment.content ?? "", baseFont: 1)
        case .forum(let title, let body):
            if !title.isEmpty, title != store.item.title {
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            RichText(html: body, baseFont: 1)
        case .none:
            EmptyView()
        }
    }

}

/// 评论行：头像 + 作者 / 地区 / 日期 / 点赞 + 正文。
private struct CommentRow: View {
    let comment: JDComment
    let voteKind: Bool?
    let onProfile: (() -> Void)?
    let onNotice: (String) -> Void
    let onUp: (() -> Void)?
    let onDown: (() -> Void)?
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var reportUI = ReportUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if let avatar = comment.avatar_ref, !avatar.isEmpty {
                    let url = URL(string: avatar.hasPrefix("/") ? "https://jandan.net" + avatar : avatar)
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color(.secondarySystemBackground)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                }
                Button { onProfile?() } label: {
                    Text(comment.author ?? "匿名")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(onProfile == nil)
                .contextMenu {
                    if let author = comment.author, !author.isEmpty {
                        Button(role: .destructive) {
                            banned.block(userID: comment.user_id, nickname: author)
                        } label: {
                            Label("屏蔽用户", systemImage: "hand.raised.slash")
                        }
                    }
                    if ReportStore.shared.isReported(comment.id) {
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
                            FavoriteStore.shared.isFavorite(comment.id) ? "取消收藏" : "收藏",
                            systemImage: FavoriteStore.shared.isFavorite(comment.id) ? "bookmark.fill" : "bookmark"
                        )
                    }
                }
                if comment.id < 0 {
                    Text("待审核")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let loc = comment.ip_location, !loc.isEmpty {
                    Text(loc).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let date = comment.date_gmt {
                    Text(date.jdShortDate).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    Button { onUp?() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                            Text("\(comment.vote_positive ?? 0)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onUp == nil || voteKind != nil)
                    .foregroundStyle(voteKind == true ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("vote-up-\(comment.id)")
                    Button { onDown?() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsdown")
                            Text("\(comment.vote_negative ?? 0)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onDown == nil || voteKind != nil)
                    .foregroundStyle(voteKind == false ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("vote-down-\(comment.id)")
                }
                .font(.caption.weight(.semibold))
            }
            RichText(html: comment.content ?? "", baseFont: 0.9)
        }
        .padding(.vertical, 10)
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
                try await JDAPI.report(commentID: comment.id, reason: reason, type: type)
                ReportStore.shared.mark(comment.id)
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
            if FavoriteStore.shared.isFavorite(comment.id) {
                await FavoriteStore.shared.remove(commentID: comment.id)
            } else {
                await FavoriteStore.shared.add(commentID: comment.id)
            }
        }
    }
}
