import SwiftUI
import UIKit

/// 用户中心（原生）：登录 / 账号信息 / 退出。
struct AccountView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if auth.isLoggedIn {
                    profile
                } else {
                    LoginView()
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("用户中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task { await auth.refresh() }
    }

    private var profile: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(auth.user?.nickname ?? "煎蛋用户")
                            .font(.headline)
                        if (auth.user?.membership ?? 0) > 0 {
                            Text("订阅会员").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Button(role: .destructive) {
                    Task { await auth.logout() }
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }
}

/// 登录表单：图选验证码 + 用户名 + 密码（SHA3-256 由 AuthStore 处理）
struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var form = LoginFormState()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 24)

                // 微信扫码登录入口：直接打开扫码页，无需输入验证码和密码。
                Button {
                    form.showWeChatLogin = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                        Text("微信扫码登录")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal)
                .sheet(isPresented: $form.showWeChatLogin) {
                    WeChatLoginView()
                        .environmentObject(auth)
                }

                HStack(spacing: 10) {
                    Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                    Text("或使用账号密码").font(.caption2).foregroundStyle(.tertiary)
                    Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    TextField("用户名", text: $form.username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $form.password)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                if let captcha = auth.captcha {
                    VStack(spacing: 8) {
                        Text(auth.captchaVerified ? "验证通过，请登录" : (captcha.prompt ?? "请点击图片中的目标"))
                            .font(.caption)
                            .foregroundStyle(auth.captchaVerified ? Color.green : Color.secondary)
                        CaptchaView(imageBase64: captcha.image ?? "") { point in
                            await auth.verifyCaptcha(x: point.x, y: point.y)
                        }
                        Button {
                            Task { await auth.loadCaptcha() }
                        } label: {
                            Label("换一张", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                } else {
                    Button("加载验证码") {
                        Task { await auth.loadCaptcha() }
                    }
                    .buttonStyle(.bordered)
                }

                if let message = auth.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await auth.login(username: form.username, password: form.password) }
                } label: {
                    if auth.isLoggingIn {
                        ProgressView()
                    } else {
                        Text("登录").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(auth.isLoggingIn)
                .padding(.horizontal)

                Text("登录态由煎蛋网站 Cookie 管理，本 App 不保存密码。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .task { await auth.loadCaptcha() }
    }
}

final class LoginFormState: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var showWeChatLogin = false
}

/// 图选验证码：显示 base64 图片，点击坐标归一化后交给验证接口。
private struct CaptchaView: View {
    let imageBase64: String
    let onTap: (CGPoint) async -> Bool

    @StateObject private var imageState = CaptchaImageState()

    var body: some View {
        Group {
            if let image = imageState.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        let size = image.size
                        let normalized = CGPoint(
                            x: point.x / size.width,
                            y: point.y / size.height
                        )
                        Task { _ = await onTap(normalized) }
                    }
            } else {
                Color(.secondarySystemBackground)
                    .frame(height: 120)
                    .overlay(ProgressView())
            }
        }
        .onChange(of: imageBase64) { _, newValue in imageState.decode(newValue) }
        .onAppear { imageState.decode(imageBase64) }
    }
}

@MainActor
final class CaptchaImageState: ObservableObject {
    @Published var image: UIImage?
    private var lastBase64 = ""

    func decode(_ base64: String) {
        guard base64 != lastBase64, !base64.isEmpty else { return }
        lastBase64 = base64
        // data:image/png;base64,xxxx → 只取第一个逗号后的载荷。
        // 不能按 "data:image/" 和 ";base64," 分别删除，否则会残留 "png" 前缀导致解码失败。
        let payload: String
        if let comma = base64.firstIndex(of: ",") {
            payload = String(base64[base64.index(after: comma)...])
        } else {
            payload = base64
        }
        let clean = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: clean) {
            image = UIImage(data: data)
        }
    }
}
