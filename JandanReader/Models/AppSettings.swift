import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let dark = "jd_dark_mode"
        static let clean = "jd_clean_mode"
        static let font = "jd_font_scale"
        static let channel = "jd_last_channel"
    }

    private let defaults = UserDefaults.standard

    @Published var darkMode: Bool {
        didSet { defaults.set(darkMode, forKey: Key.dark) }
    }
    @Published var cleanMode: Bool {
        didSet { defaults.set(cleanMode, forKey: Key.clean) }
    }
    @Published var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Key.font) }
    }
    @Published var lastChannelID: String {
        didSet { defaults.set(lastChannelID, forKey: Key.channel) }
    }

    init() {
        defaults.register(defaults: [
            Key.dark: false,
            Key.clean: true,
            Key.font: 100.0,
            Key.channel: Channel.home.id,
        ])
        darkMode = defaults.bool(forKey: Key.dark)
        cleanMode = defaults.bool(forKey: Key.clean)
        fontScale = defaults.double(forKey: Key.font)
        lastChannelID = defaults.string(forKey: Key.channel) ?? Channel.home.id
    }

    var fontSizePercent: Int { Int(fontScale) }
}
