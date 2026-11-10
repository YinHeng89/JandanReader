import SwiftUI
import WebKit
import UIKit

struct WebViewContainer: UIViewRepresentable {
    let store: WebStore

    func makeUIView(context: Context) -> WebHostView {
        let host = WebHostView()
        bind(host)
        return host
    }

    func updateUIView(_ host: WebHostView, context: Context) {
        // 频道切换时 SwiftUI 复用同一个 representable，只会走 updateUIView。
        // 必须在这里换挂新频道的 WKWebView，否则画面一直停在启动时那个频道。
        bind(host)
    }

    private func bind(_ host: WebHostView) {
        host.owningStore = store
        let changed = host.attach(store.webView)
        store.host = host
        // 换挂不触发任何 WKNavigationDelegate 回调，didStart / didCommit 的
        // syncDark() 不会跑。主动同步一次，避免切频道瞬间露出旧主题渲染。
        if changed { store.applySettings() }
    }
}

/// 承载 WKWebView 的容器视图。
/// WKWebView 由 WebRouter 强持有，这里只负责换挂，切走时不销毁，
/// 因此各频道的滚动位置与浏览栈都能保留。
///
/// 为什么自己实现返回手势：
/// WKWebView 自带的 allowsBackForwardNavigationGestures 在滑动过程中显示的是
/// WKBackForwardListItem 缓存的位图快照，快照在「离开该页时」按当时的主题捕获，
/// 不是 DOM，evaluateJavaScript 改不到，也刷不新。切过主题后再返回，
/// 旧深色位图就会在过渡动画里露出来，直到 live 页面接管才变浅。
/// 因此这里关闭系统手势，改为自己接管：过渡期间显示的是当前 live 页面的
/// 实时快照（已按当前主题渲染），与被缓存的历史位图彻底无关。
@MainActor
final class WebHostView: UIView, UIGestureRecognizerDelegate {

    private weak var current: WKWebView?
    private var backdrop: UIView?
    private var snapshot: UIView?
    private var edgePan: UIScreenEdgePanGestureRecognizer!
    private var transitioning = false

    /// 一个 host 会在频道切换时被复用给不同的 store，用它校验过渡归属，
    /// 避免后台 store 的回调误操作当前画面。
    weak var owningStore: WebStore?

    /// 主题色以 UIKit trait 为准（SwiftUI 的 preferredColorScheme 不一定传导到
    /// 这里），显式覆盖后 .systemBackground 才能解析出正确的深浅。
    var darkMode = false {
        didSet {
            overrideUserInterfaceStyle = darkMode ? .dark : .light
            backdrop?.backgroundColor = .systemBackground
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanChanged(_:)))
        gesture.edges = .left
        gesture.delegate = self
        addGestureRecognizer(gesture)
        edgePan = gesture
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func attach(_ webView: WKWebView) -> Bool {
        if current === webView, webView.superview === self { return false }
        clearTransition(immediately: true)
        current?.removeFromSuperview()
        webView.removeFromSuperview()
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        addSubview(webView)
        current = webView
        bringGestureToFrontIfNeeded()
        return true
    }

    /// 手势挂在 self 上，subview 的增删不影响它；这里只确保过渡层在最上层。
    private func bringGestureToFrontIfNeeded() {
        if let backdrop { bringSubviewToFront(backdrop) }
        if let snapshot { bringSubviewToFront(snapshot) }
    }

    // MARK: - 自己接管的返回手势

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 没有历史可返回时不拦截，左边缘仍然交给网页本身（滚动 / 侧滑菜单）。
        guard !transitioning else { return false }
        return owningStore?.canGoBack == true
    }

    /// 有历史可返回时，让边缘手势优先于 WKWebView.scrollView 的 pan，
    /// 否则左边缘起手会被网页滚动吃掉，自建手势永远收不到 .began。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === edgePan, owningStore?.canGoBack == true else { return false }
        return otherGestureRecognizer !== edgePan
    }

    @objc private func edgePanChanged(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let dx = max(0, gesture.translation(in: self).x)

        switch gesture.state {
        case .began:
            guard owningStore?.canGoBack == true else { return }
            beginTransition()

        case .changed:
            // 阻尼位移给一点跟手反馈，但不要把整页拖走：
            // 下面露出的仍是当前页，全量跟手会出现「页面滑走露出自己」的怪象。
            let offset = min(dx * 0.32, bounds.width * 0.26)
            snapshot?.transform = CGAffineTransform(translationX: offset, y: 0)

        case .ended:
            let vx = gesture.velocity(in: self).x
            if dx >= 90 || vx >= 650 {
                commitTransition()
            } else {
                cancelTransition()
            }

        case .cancelled, .failed:
            cancelTransition()

        default:
            break
        }
    }

    private func beginTransition() {
        transitioning = true
        // 先截 live 页面：此时 DOM 已是当前主题，拿到的一定是浅色/深色正确的一帧。
        let snap = current?.snapshotView(afterScreenUpdates: true)
        let back = UIView(frame: bounds)
        back.backgroundColor = .systemBackground
        back.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        back.isUserInteractionEnabled = false
        addSubview(back)
        backdrop = back

        if let snap {
            snap.frame = bounds
            snap.isUserInteractionEnabled = false
            addSubview(snap)
            snapshot = snap
        }
        // 快照可能拿不到（WKWebView 合成层偶发），此时至少是不透明的主题色底，
        // 不会露出 WebKit 的旧深色位图。
    }

    private func commitTransition() {
        snapshot?.transform = .identity
        owningStore?.goBack()
        // goBack 可能走 page cache 而不触发 didFinish，硬超时兜底。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            self.clearTransition(immediately: false)
        }
    }

    private func cancelTransition() {
        UIView.animate(withDuration: 0.18, animations: {
            self.snapshot?.transform = .identity
        }) { _ in
            self.clearTransition(immediately: false)
        }
    }

    /// 由 WebStore 在 didCommit / didFinish 调用：目标页已按当前主题接入，
    /// 稍微延后一点让 syncDark() 的 JS 生效，再淡出过渡层。
    func finishBackTransition() {
        guard transitioning else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            self.clearTransition(immediately: false)
        }
    }

    private func clearTransition(immediately: Bool) {
        transitioning = false
        let snap = snapshot
        let back = backdrop
        snapshot = nil
        backdrop = nil
        guard snap != nil || back != nil else { return }

        let remove = {
            snap?.removeFromSuperview()
            back?.removeFromSuperview()
        }
        if immediately {
            remove()
        } else {
            UIView.animate(withDuration: 0.16, animations: {
                snap?.alpha = 0
                back?.alpha = 0
            }, completion: { _ in remove() })
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        current?.frame = bounds
        backdrop?.frame = bounds
        // snapshot 的尺寸只在 beginTransition 时按当时 bounds 设定。
        // 这里绝不重设 frame：UIView 在 transform 非 identity 时 frame 语义未定义，
        // 重设会把手势跟手的位移直接冲掉。
    }
}
