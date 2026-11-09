import SwiftUI

@main
@MainActor
struct JandanReaderApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var history = HistoryStore()
    @StateObject private var router = WebRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(router)
        }
    }
}
