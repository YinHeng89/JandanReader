import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let symbol: String
    let path: String

    var url: URL {
        URL(string: "https://jandan.net" + path)!
    }

    /// 只保留三个板块。首页走时间线接口，无聊图 / 女装走图片流接口。
    static let all: [Channel] = [
        .init(id: "home",   title: "首页",   symbol: "house.fill", path: "/"),
        .init(id: "pic",    title: "无聊图", symbol: "photo.fill", path: "/pic"),
        .init(id: "beauty", title: "女装",   symbol: "tshirt.fill", path: "/beauty"),
    ]

    static let home = all[0]

    static func withID(_ id: String) -> Channel {
        all.first { $0.id == id } ?? .home
    }
}
