import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let dark = "jd_dark_mode"
        /// 沿用旧 key，避免升级后用户设置丢失；云同步字段同样仍叫 cleanMode。
        static let thumbnails = "jd_clean_mode"
        static let font = "jd_font_scale"
        static let channel = "jd_last_channel"
    }

    private let defaults = UserDefaults.standard

    @Published var darkMode: Bool {
        didSet {
            defaults.set(darkMode, forKey: Key.dark)
            PrefsStore.shared.notifyLocalChange()
        }
    }

    /// 只控制图片尺寸（开启加载 600px 缩略图，关闭加载 large 原图）。
    /// 旧版同时用它控制首页摘要行数，属于一个开关两种语义，已拆分。
    @Published var useThumbnails: Bool {
        didSet {
            defaults.set(useThumbnails, forKey: Key.thumbnails)
            PrefsStore.shared.notifyLocalChange()
        }
    }

    @Published var fontScale: Double {
        didSet {
            defaults.set(fontScale, forKey: Key.font)
            PrefsStore.shared.notifyLocalChange()
        }
    }
    @Published var lastChannelID: String {
        didSet { defaults.set(lastChannelID, forKey: Key.channel) }
    }

    init() {
        defaults.register(defaults: [
            Key.dark: false,
            Key.thumbnails: true,
            Key.font: 100.0,
            Key.channel: Channel.home.id,
        ])
        darkMode = defaults.bool(forKey: Key.dark)
        useThumbnails = defaults.bool(forKey: Key.thumbnails)
        fontScale = defaults.double(forKey: Key.font)
        lastChannelID = defaults.string(forKey: Key.channel) ?? Channel.home.id
    }

    var fontSizePercent: Int { Int(fontScale) }
}
