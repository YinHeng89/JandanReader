import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: WebRouter

    @State private var selected: Channel = .home
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showShare = false
    @State private var didConfigure = false

    private var store: WebStore? { router.store(for: selected) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ChannelBar(selected: $selected)
            ProgressLine(progress: store?.progress ?? 0, isLoading: store?.isLoading ?? false)

            webContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) { bottomToolbar }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(settings.darkMode ? .dark : .light)
        .onAppear {
            guard !didConfigure else { return }
            didConfigure = true
            router.configure(settings: settings, history: history) { url in
                UIApplication.shared.open(url)
            }
            selected = Channel.withID(settings.lastChannelID)
            router.ensure(selected)
        }
        .onChange(of: selected) { _, newValue in
            settings.lastChannelID = newValue.id
            router.ensure(newValue)
        }
        .onChange(of: settings.darkMode) { _, _ in router.applySettings() }
        .onChange(of: settings.cleanMode) { _, _ in router.applySettings() }
        .onChange(of: settings.fontScale) { _, _ in router.applySettings() }
        .sheet(isPresented: $showSettings) {
            SettingsView { url in
                router.open(url, in: selected)
            }
            .environmentObject(settings)
            .environmentObject(history)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView { url in
                router.open(url, in: selected)
            }
            .environmentObject(history)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(url: store?.shareURL ?? Channel.home.url)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("煎蛋")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("地球上没有新鲜事")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { showHistory = true } label: {
                IconButton(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            Button { settings.darkMode.toggle() } label: {
                IconButton(systemName: settings.darkMode ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.plain)
            Button { showSettings = true } label: {
                IconButton(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
    }

    // MARK: - Web area

    @ViewBuilder
    private var webContent: some View {
        ZStack {
            Color(.systemBackground)

            if let store {
                WebViewContainer(store: store)

                if let message = store.errorMessage {
                    errorCard(message: message) { store.reload() }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Color.accentColor)
                    Text("正在打开 \(selected.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }

    private func errorCard(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            Text("页面加载失败")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).opacity(0.75))
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                ToolButton(systemName: "chevron.left", enabled: store?.canGoBack ?? false) {
                    store?.goBack()
                }
                ToolButton(systemName: "chevron.right", enabled: store?.canGoForward ?? false) {
                    store?.goForward()
                }
                ToolButton(systemName: "arrow.clockwise") {
                    store?.reload()
                }
                ToolButton(systemName: "house") {
                    store?.loadChannel()
                }
                ToolButton(systemName: "square.and.arrow.up") {
                    showShare = true
                }
                ToolButton(systemName: "safari") {
                    if let url = store?.shareURL { UIApplication.shared.open(url) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .background(.regularMaterial)
    }
}
