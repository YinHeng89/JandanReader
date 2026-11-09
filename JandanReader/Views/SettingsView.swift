import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var ui = SettingsViewState()
    let onOpen: (URL) -> Void

    private func open(_ path: String) {
        guard let url = URL(string: "https://jandan.net" + path) else { return }
        // 统一走外壳的 URL 分发（WebRouter.open 会判定功能页 → 独立页）。
        // 先 dismiss，等 sheet 完全消失再触发，避免与 fullScreenCover 抢 presentation。
        ui.pendingURL = url
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $settings.darkMode) {
                        Label("夜间模式", systemImage: "moon.fill")
                    }
                    Toggle(isOn: $settings.cleanMode) {
                        Label("纯净阅读", systemImage: "text.alignleft")
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
                    Text("纯净阅读会隐藏网页自带的导航栏、侧栏与广告位，频道切换交给原生顶部标签。关闭即可查看完整网页。")
                }

                Section {
                    Button {
                        open("/new/member")
                    } label: {
                        Label("用户中心", systemImage: "person.crop.circle")
                    }
                    Button {
                        open("/new/member/message")
                    } label: {
                        Label("消息通知", systemImage: "envelope")
                    }
                } header: {
                    Text("账户")
                }

                Section {
                    HStack {
                        Label("阅读历史", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("\(history.items.count) 条")
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        history.clear()
                    } label: {
                        Label("清空阅读历史", systemImage: "trash")
                    }
                    .disabled(history.items.isEmpty)
                    Button {
                        Task {
                            ui.clearingCache = true
                            await WebCache.clear()
                            ui.clearingCache = false
                            ui.cacheCleared = true
                        }
                    } label: {
                        HStack {
                            Label("清除网页缓存", systemImage: "xmark.circle")
                            if ui.clearingCache { Spacer(); ProgressView() }
                            if ui.cacheCleared && !ui.clearingCache {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(ui.clearingCache)
                } header: {
                    Text("数据")
                } footer: {
                    Text("仅清除图片与页面缓存，不会退出登录。")
                }

                Section {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0").foregroundStyle(.secondary)
                    }
                    Label("数据来源 jandan.net", systemImage: "link")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onDisappear {
            guard let url = ui.pendingURL else { return }
            ui.pendingURL = nil
            onOpen(url)
        }
    }
}
