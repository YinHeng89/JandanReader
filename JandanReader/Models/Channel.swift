import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let symbol: String
    let path: String

    var url: URL {
        URL(string: "https://jandan.net" + path)!
    }

    static let all: [Channel] = [
        .init(id: "home",     title: "首页",   symbol: "house.fill",                        path: "/"),
        .init(id: "top",      title: "热榜",   symbol: "flame.fill",                        path: "/top"),
        .init(id: "pic",      title: "无聊图", symbol: "photo.fill",                        path: "/pic"),
        .init(id: "ooxx",     title: "随手拍", symbol: "camera.fill",                       path: "/ooxx"),
        .init(id: "treehole", title: "树洞",   symbol: "bubble.left.and.bubble.right.fill", path: "/treehole"),
        .init(id: "qa",       title: "问答",   symbol: "questionmark.circle.fill",          path: "/qa"),
        .init(id: "beauty",   title: "女装",   symbol: "tshirt.fill",                       path: "/beauty"),
        .init(id: "forum",    title: "鱼塘",   symbol: "fish.fill",                         path: "/new/forum"),
        .init(id: "daily",    title: "日报",   symbol: "newspaper.fill",                    path: "/new/daily"),
        .init(id: "tucao",    title: "大吐槽", symbol: "megaphone.fill",                    path: "/tucao"),
    ]

    static let home = all[0]

    static func withID(_ id: String) -> Channel {
        all.first { $0.id == id } ?? .home
    }
}
