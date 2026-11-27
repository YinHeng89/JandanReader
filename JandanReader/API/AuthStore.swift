import Foundation
import SwiftUI
import UIKit
import WebKit

/// 登录态：站点用 Cookie（HTTPCookieStorage.shared），本类只负责把当前用户拉出来。
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: JDUser?
    @Published private(set) var isChecking = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var message: String?

    /// 必须 @Published：否则 loadCaptcha 异步赋值后 LoginView 不会重绘，验证码区域始终空白。
    @Published private(set) var captcha: JDCaptcha?
    /// 图选验证码是否已通过。站点登录前必须先 verify，否则 /member/login 会被拒。
    @Published private(set) var captchaVerified = false

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

    /// - parameter keepMessage: 验证失败后换图时保留错误提示，否则用户不知道点没点中。
    func loadCaptcha(keepMessage: Bool = false) async {
        if !keepMessage { message = nil }
        captcha = nil
        captchaVerified = false
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
            captchaVerified = true
            return true
        } catch {
            message = "验证未通过，请重新点击：\(error.localizedDescription)"
            // 验证失败后必须换新图（旧图已被服务端作废），但保留提示让用户知道没点中。
            await loadCaptcha(keepMessage: true)
            return false
        }
    }

    // MARK: 登录

    /// 密码按站点规则做 Keccak-256（CryptoJS `SHA3(...,{outputLength:256})`, hex）。
    /// 注意不是 FIPS 202 SHA3-256，两者 domain separator 不同。
    func login(username: String, password: String) async -> Bool {
        guard !username.isEmpty, !password.isEmpty else {
            message = "请输入用户名和密码"
            return false
        }
        guard captchaVerified else {
            message = "请先点击验证码图片完成验证"
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

    /// 退出登录：服务端失败也必须清掉本地 Cookie，否则下次 refresh() 会把
    /// 旧会话重新拉回来，界面显示「已退出」实际仍是登录态。
    func logout() async {
        do {
            try await JDAPI.postRaw("/api/member/logout", form: [:])
            message = nil
        } catch {
            message = "退出登录失败：\(error.localizedDescription)（本地登录态已清除）"
        }
        await clearLoginCookies()
        user = nil
        captcha = nil
        captchaVerified = false
    }

    private func clearLoginCookies() async {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where cookie.domain.contains("jandan.net") {
            storage.deleteCookie(cookie)
        }
        // 微信登录曾把 WKWebView 的 Cookie 同步过来；WebView 侧也要清，
        // 否则下次打开扫码页会带着旧会话自动登录。
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where cookie.domain.contains("jandan.net") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }
}
