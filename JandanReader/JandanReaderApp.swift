import SwiftUI

@main
@MainActor
struct JandanReaderApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var history = HistoryStore()
    @StateObject private var router = FeedRouter()
    @StateObject private var auth = AuthStore()
    @StateObject private var banned = BannedStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(router)
                .environmentObject(auth)
                .environmentObject(banned)
        }
    }
}
