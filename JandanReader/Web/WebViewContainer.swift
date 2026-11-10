import SwiftUI
import WebKit

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
@MainActor
final class WebHostView: UIView {
    private weak var current: WKWebView?
    private var cover: UIView?
    private var hookedRecognizers: [UIGestureRecognizer] = []

    /// 一个 host 会在频道切换时被复用给不同的 store，用它校验遮罩归属，
    /// 避免后台 store 的回调误盖到当前画面。
    weak var owningStore: WebStore?

    /// 主题色以 UIKit trait 为准（SwiftUI 的 preferredColorScheme 不一定传导到
    /// 这里），显式覆盖后 .systemBackground 才能解析出正确的深浅。
    var darkMode = false {
        didSet {
            overrideUserInterfaceStyle = darkMode ? .dark : .light
            cover?.backgroundColor = .systemBackground
        }
    }

    @discardableResult
    func attach(_ webView: WKWebView) -> Bool {
        if current === webView, webView.superview === self { return false }
        current?.removeFromSuperview()
        webView.removeFromSuperview()
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        addSubview(webView)
        current = webView
        // 新挂上的 view 会压在遮罩之上，把遮罩重新提到最前。
        if let cover { bringSubviewToFront(cover) }
        hookEdgePan(webView)
        return true
    }

    /// 真实的手势返回可能走 page cache 恢复，不经过 decidePolicyFor。
    /// 直接挂到 WKWebView 的边缘手势上（UIScreenEdgePanGestureRecognizer
    /// 是公开类），确保过渡一开始就盖住旧快照。
    private func hookEdgePan(_ webView: WKWebView) {
        for g in hookedRecognizers {
            g.removeTarget(self, action: #selector(edgePanChanged(_:)))
        }
        hookedRecognizers.removeAll()
        let views: [UIView] = [webView, webView.scrollView]
        for view in views {
            for g in view.gestureRecognizers ?? [] where g is UIScreenEdgePanGestureRecognizer {
                g.addTarget(self, action: #selector(edgePanChanged(_:)))
                hookedRecognizers.append(g)
            }
        }
    }

    @objc private func edgePanChanged(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            owningStore?.beginThemeCover()
        case .cancelled, .failed:
            owningStore?.endThemeCover()
        case .ended:
            // 手势结束后页面可能还没 commit，给 didCommit 一点时间，
            // 超时兜底隐藏，避免 delegate 没回调时一直盖着。
            owningStore?.scheduleThemeCoverRelease()
        default:
            break
        }
    }

    /// 手势返回期间 WKWebView 显示的是历史条目的位图快照，不是 DOM，
    /// JS 无法改写。用当前主题色盖住它，文档提交后淡出，避免闪深色。
    func showThemeCover(_ show: Bool) {
        if show {
            guard cover == nil else { return }
            let view = UIView(frame: bounds)
            view.backgroundColor = .systemBackground
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            addSubview(view)
            cover = view
        } else {
            guard let view = cover else { return }
            cover = nil
            UIView.animate(withDuration: 0.16, animations: { view.alpha = 0 }) { _ in
                view.removeFromSuperview()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        current?.frame = bounds
        cover?.frame = bounds
    }
}
