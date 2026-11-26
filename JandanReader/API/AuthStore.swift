import Foundation
import SwiftUI
import UIKit

/// 登录态：站点用 Cookie（HTTPCookieStorage.shared），本类只负责把当前用户拉出来。
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: JDUser?
    @Published private(set) var isChecking = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var message: String?

    private(set) var captcha: JDCaptcha?
    private var captchaCookie: HTTPCookie?

    func refresh(force: Bool = false) async {
        if user != nil && !force { return }
        isChecking = true
        defer { isChecking = false }
        do {
            user = try await JDAPI.get("/api/member/get_info", as: JDUser.self)
        } catch {
            user = nil
        }
    }

    var isLoggedIn: Bool { user != nil }

    // MARK: 图选验证码

    func loadCaptcha() async {
        message = nil
        captcha = nil
        do {
            let result = try await JDAPI.get(
                "/api/captcha/challenge",
                query: ["t": "\(Int(Date().timeIntervalSince1970 * 1000))"],
                as: JDCaptcha.self
            )
            captcha = result
        } catch {
            message = error.localizedDescription
        }
    }

    /// 用户点击验证码图的归一化坐标（0~1）
    func verifyCaptcha(x: Double, y: Double) async -> Bool {
        do {
            try await JDAPI.postRaw("/api/captcha/verify", form: [
                "x": String(format: "%.4f", x),
                "y": String(format: "%.4f", y),
            ])
            return true
        } catch {
            message = error.localizedDescription
            await loadCaptcha()
            return false
        }
    }

    // MARK: 登录

    /// 密码按站点规则做 SHA3-256（CryptoJS outputLength=256, hex）
    func login(username: String, password: String) async -> Bool {
        guard !username.isEmpty, !password.isEmpty else {
            message = "请输入用户名和密码"
            return false
        }
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            try await JDAPI.postRaw("/api/member/login", form: [
                "username": username,
                "password": SHA3.sha256Hex(password),
            ])
            await refresh(force: true)
            if isLoggedIn {
                message = nil
                captcha = nil
                return true
            }
            message = "登录状态获取失败，请重试"
        } catch {
            message = error.localizedDescription
        }
        return false
    }

    func logout() async {
        try? await JDAPI.postRaw("/api/member/logout", form: [:])
        user = nil
    }
}
