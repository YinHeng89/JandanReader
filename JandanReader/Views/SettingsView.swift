import SwiftUI

/// sheet 有独立环境，父级的 preferredColorScheme 不会实时下发；这里单独绑定并稍作延迟。
@MainActor
private final class SettingsTheme: ObservableObject {
    @Published var scheme: ColorScheme?
    @Published var showHistory = false
    @Published var cacheUsage: ImageCache.Usage = .zero
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var banned: BannedStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var theme = SettingsTheme()
    /// 作为底部 Tab 时常驻，不需要「完成」关闭按钮。
    var showsDoneButton: Bool = true

    @MainActor
    private func refreshCacheUsage() async {
        theme.cacheUsage = await ImageCache.readUsage()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            router.openAccount()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("个人中心").font(.system(size: 15, weight: .semibold))
                                Text("登录、账户信息与订阅").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("账户")
                }

                Section {
                    Toggle(isOn: $settings.darkMode) {
                        Label("夜间模式", systemImage: "moon.fill")
                    }
                    Toggle(isOn: $settings.cleanMode) {
                        Label("显示缩略图", systemImage: "photo")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("正文字号", systemImage: "textformat.size")
                            Spacer()
                            Text("\(settings.fontSizePercent)%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.fontScale, in: 90...130, step: 5)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("外观")
                } footer: {
                    Text("显示缩略图加载 600px 小图，关闭后加载原图。")
                }

                Section {
                    NavigationLink {
                        BannedUsersView()
                    } label: {
                        HStack {
                            Label("屏蔽的用户", systemImage: "hand.raised.slash")
                            Spacer()
                            Text("\(banned.entries.count) 人")
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        FavoritesView()
                            .environmentObject(auth)
                            .environmentObject(router)
                            .environmentObject(settings)
                    } label: {
                        HStack {
                            Label("我的收藏", systemImage: "bookmark")
                            Spacer()
                            if auth.isLoggedIn {
                                Text("\(FavoriteStore.shared.commentIDs.count) 条")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("需登录").foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        NotificationsView()
                            .environmentObject(auth)
                            .environmentObject(settings)
                    } label: {
                        HStack {
                            Label("消息通知", systemImage: "bell")
                            Spacer()
                            if auth.isLoggedIn && NoticeStore.shared.unread > 0 {
                                Text("\(NoticeStore.shared.unread) 条未读")
                                    .foregroundStyle(.secondary)
                            } else if !auth.isLoggedIn {
                                Text("需登录").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if PrefsStore.shared.canSync {
                        HStack {
                            Label("偏好云同步", systemImage: "icloud")
                            Spacer()
                            Text(PrefsStore.shared.isSynced ? "已同步" : "待同步")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("内容")
                } footer: {
                    Text(PrefsStore.shared.canSync
                         ? "订阅会员的屏蔽名单与显示设置会同步到云端，本地数据始终保留。"
                         : "屏蔽后该作者的内容与评论将不再显示，仅保存在本机。")
                }

                Section {
                    Button { theme.showHistory = true } label: {
                        HStack {
                            Label("阅读历史", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Text("\(history.items.count) 条")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack {
                        Label("图片缓存", systemImage: "externaldrive")
                        Spacer()
                        Text(theme.cacheUsage.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Button(role: .destructive) {
                        ImageCache.clear()
                        Task { await refreshCacheUsage() }
                    } label: {
                        Label("清除图片缓存", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        history.clear()
                    } label: {
                        Label("清空阅读历史", systemImage: "trash")
                    }
                    .disabled(history.items.isEmpty)
                } header: {
                    Text("数据")
                } footer: {
                    Text("缓存包含网络图片与内存中的解码图；清除后重新加载会消耗流量。阅读历史只保存在本机，不会上传。")
                }

                Section {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0").foregroundStyle(.secondary)
                    }
                    Label("数据来源 jandan.net REST API", systemImage: "link")
                        .foregroundStyle(.secondary)
                    Text("非官方客户端，内容版权归煎蛋网所有。仅供个人使用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $theme.showHistory) {
                HistoryView()
                    .environmentObject(history)
                    .environmentObject(router)
                    .environmentObject(settings)
            }
        }
        .onAppear {
            theme.scheme = settings.darkMode ? .dark : .light
            Task { await refreshCacheUsage() }
        }
        .onChange(of: settings.darkMode) { _, dark in
            // 稍延迟让开关状态先提交，随后再切换 sheet 环境。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                theme.scheme = dark ? .dark : .light
            }
        }
        .preferredColorScheme(theme.scheme)
    }
}
