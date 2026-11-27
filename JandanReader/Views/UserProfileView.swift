import SwiftUI

/// 作者个人主页：游客可用，四个公开端点聚合（资料 / 勋章 / 评论 / 吐槽）。
struct UserProfileView: View {
    let userID: Int
    let nickname: String
    /// 打开该用户的内容时落到哪个频道，由外壳显式注入。
    let channel: Channel

    @StateObject private var store: UserProfileStore
    @StateObject private var ui = ProfileUIState()
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var router: FeedRouter
    @Environment(\.dismiss) private var dismiss

    init(userID: Int, nickname: String, channel: Channel) {
        self.userID = userID
        self.nickname = nickname
        self.channel = channel
        _store = StateObject(wrappedValue: UserProfileStore(userID: userID))
    }

    private var displayName: String { store.profile?.nickname ?? nickname }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.isLoading {
                    HStack {
                        ProgressView().tint(Color.accentColor)
                        Text("加载中…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    if !store.badges.isEmpty { badgesSection }
                    if !store.comments.isEmpty { listSection("评论", store.comments) }
                    if !store.tucaos.isEmpty { listSection("吐槽", store.tucaos) }
                    if store.comments.isEmpty && store.tucaos.isEmpty {
                        Text("暂无公开内容")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("个人主页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    ui.showBlockConfirm = true
                } label: {
                    Image(systemName: "hand.raised.slash")
                }
                .accessibilityLabel("屏蔽用户")
            }
        }
        .confirmationDialog("屏蔽用户", isPresented: $ui.showBlockConfirm) {
            Button("屏蔽用户", role: .destructive) {
                banned.block(userID: userID, nickname: displayName)
                store.showToast("已屏蔽用户")
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("屏蔽后该用户的内容将不再显示")
        }
        .toast(message: Binding(
            get: { store.toastMessage },
            set: { store.toastMessage = $0 }
        ))
        .task { await store.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            avatar(url: store.profile?.avatar_ref, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 18, weight: .bold))
                Text("ID \(userID)")
                    .font(.caption).foregroundStyle(.secondary)
                if let reg = store.profile?.reg_time, !reg.isEmpty {
                    Text("注册 \(String(reg.prefix(10)))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("勋章 · \(store.badges.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.badges) { badge in
                        Text(badge.badge_name ?? "勋章")
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                badge.isWearing
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(badge.isWearing ? Color.accentColor : Color.secondary)
                    }
                }
            }
        }
    }

    private func listSection(_ title: String, _ items: [JDComment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(items.count)")
                .font(.headline)
            ForEach(items) { comment in
                Button { open(comment) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(comment.post_title ?? title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let date = comment.date_gmt {
                                Text(date.jdShortDate)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        // 无聊图正文常是纯 <img> 标签，必须走 RichText 才能显示图片；
                        // 用 plain 会把标签剥掉只剩空文字。
                        RichText(html: comment.content ?? "", baseFont: 0.9)
                        HStack(spacing: 12) {
                            Label("\(comment.vote_positive ?? 0)", systemImage: "hand.thumbsup")
                            Label("\(comment.vote_negative ?? 0)", systemImage: "hand.thumbsdown")
                            if let location = comment.ip_location, !location.isEmpty {
                                Text(location)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ comment: JDComment) {
        router.openArticle(
            id: comment.id,
            title: comment.post_title ?? "详情",
            kind: "comment",
            in: channel
        )
    }

    @ViewBuilder
    private func avatar(url raw: String?, size: CGFloat) -> some View {
        Group {
            if let url = JDAPI.avatarURL(raw) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                }
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

final class ProfileUIState: ObservableObject {
    @Published var showBlockConfirm = false
}
