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
                        Text(captcha.prompt ?? "请点击图片中的目标").font(.caption)
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
        let clean = base64
            .replacingOccurrences(of: "data:image/", with: "")
            .replacingOccurrences(of: ";base64,", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: clean) {
            image = UIImage(data: data)
        }
    }
}
