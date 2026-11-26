import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: FeedRouter
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var banned: BannedStore

    @StateObject private var ui = ContentViewState()

    var body: some View {
        tabView
            .background(Color(.systemBackground).ignoresSafeArea())
            .preferredColorScheme(settings.darkMode ? .dark : .light)
            .onAppear {
                guard !ui.didConfigure else { return }
                ui.didConfigure = true
                router.configure(
                    history: history,
                    openAccount: { ui.showAccount = true },
                    openExternally: { url in UIApplication.shared.open(url) }
                )
                router.switchChannel = { channel in ui.selected = .channel(channel) }
                // TabView 三个 tab 同时存在，先把各自的 store 建好。
                Channel.all.forEach { router.ensure($0) }
                ui.selected = .channel(Channel.withID(settings.lastChannelID))
            }
            .onChange(of: ui.selected) { _, newValue in
                if case .channel(let channel) = newValue {
                    settings.lastChannelID = channel.id
                }
            }
            .fullScreenCover(isPresented: $ui.showAccount) {
                AccountView()
                    .environmentObject(auth)
            }
    }

    // MARK: - Tabs（Apple 官方 TabView / Tab，iOS 26 自动液态玻璃）

    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    Tab(channel.title, systemImage: channel.symbol, value: AppTab.channel(channel)) {
                        navigationContent(for: channel)
                    }
                }
                Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                    settingsTab
                }
            }
        } else {
            TabView(selection: $ui.selected) {
                ForEach(Channel.all) { channel in
                    navigationContent(for: channel)
                        .tabItem {
                            Label(channel.title, systemImage: channel.symbol)
                        }
                        .tag(AppTab.channel(channel))
                }
                settingsTab
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(AppTab.settings)
            }
        }
    }

    @ViewBuilder
    private var settingsTab: some View {
        SettingsView(showsDoneButton: false)
            .environmentObject(settings)
            .environmentObject(history)
            .environmentObject(router)
            .environmentObject(banned)
    }

    @ViewBuilder
    private func navigationContent(for channel: Channel) -> some View {
        if let store = router.store(for: channel) {
            NavigationStack(path: store.binding) {
                channelView(for: channel, store: store)
                    .environmentObject(settings)
                    .navigationTitle(channel.title)
                    .navigationDestination(for: JDNavigation.self) { route in
                        destinationView(for: route)
                    }
            }
        } else {
            ProgressView().tint(Color.accentColor)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func channelView(for channel: Channel, store: FeedStore) -> some View {
        switch channel.id {
        case "pic", "beauty":
            PhotoFeedView(store: store).environmentObject(settings)
        default:
            HomeFeedView(store: store).environmentObject(settings)
        }
    }

    private func destinationView(for route: JDNavigation) -> some View {
        PostDetailView(item: item(from: route))
            .environmentObject(settings)
            .environmentObject(router)
            .environmentObject(banned)
    }

    private func item(from route: JDNavigation) -> JDFeedItem {
        switch route {
        case .feed(let feed): return feed
        case .article(let id):
            return JDFeedItem(id: id, kind: .article, title: "", body: "", author: "", date: "",
                              imageURL: nil, commentCount: 0, positive: 0, negative: 0,
                              location: nil, avatar: nil)
        case .externalArticle(let id, let title, let kind):
            return JDFeedItem(id: id, kind: kind, title: title, body: "", author: "", date: "",
                              imageURL: nil, commentCount: 0, positive: 0, negative: 0,
                              location: nil, avatar: nil)
        }
    }
}
