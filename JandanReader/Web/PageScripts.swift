import Foundation

/// 注入到 WKWebView 的 CSS / JS。
///
/// 煎蛋首页是服务端渲染的 Bootstrap 页面：
///   #header 顶栏、#nav 主导航、#footer 页脚、#float-window 广告浮窗、
///   [id^=sidebar] 侧栏、.adsbygoogle 广告位、.header-h1 栏目标题。
/// 原生壳自己提供频道条与工具栏，因此这些元素全部隐藏，只留正文。
///
/// 站点自带暗色模式：localStorage["darkMode"] == "true" 时给 <html> 加
/// .dark-model。直接复用，比自己写一套暗色覆盖规则更贴合原站配色。
enum PageScripts {

    private static let cleanCSS = """
    #header, #nav, #footer, #float-window, #nav_top,
    [id^="sidebar"], .sidebar, .sidebar-bbs,
    .adsbygoogle, ins.adsbygoogle,
    iframe[src*="googlesyndication"], iframe[src*="doubleclick"],
    .header-h1, .breadcrumb, .model-btn, .header-model-btn,
    main.main > div.m-3, a[href*="item.taobao.com"],
    img[src*="/static/tg/"] { display: none !important; }

    #main-warpper, .wrapper { padding-top: 0 !important; margin-top: 0 !important; }
    body { padding-top: 0 !important; background-color: transparent !important; }
    .container { padding-left: 16px !important; padding-right: 16px !important; }
    main.main, .main {
      width: 100% !important; max-width: 100% !important; float: none !important;
      border-left: none !important; border-right: none !important;
    }
    .post-list { margin-top: 4px !important; }
    .post-item { margin-left: 0 !important; margin-right: 0 !important; }
    .navbar-level2 { display: none !important; }

    /* 移动端紧凑排版：评论数从左侧 30px 大数字改为右上角小徽标 */
    .post-list .post-title { padding-left: 0 !important; margin-right: 30px !important; }
    .post-list .post-tucao, .post-list .post-excerpt { padding-left: 0 !important; }
    .post-list .post-comment-count {
      top: 6px !important; left: auto !important; right: 4px !important;
      width: auto !important; font-size: 12px !important; font-weight: 700 !important;
      color: #FF7A1A !important; opacity: 0.9 !important;
    }
    """

    /// 独立功能页（用户中心 / 会员）专用：只去掉站点自身的导航、页脚、面包屑与广告。
    /// 用户中心是 JS 渲染的 SPA，不能套首页那套 .main 宽度、.post-* 排版覆盖，
    /// 否则会挤压登录表单等容器。
    static let accountCSS = """
    #header, #nav, #footer, #float-window, #nav_top,
    [id^="sidebar"], .sidebar, .sidebar-bbs,
    .adsbygoogle, ins.adsbygoogle,
    iframe[src*="googlesyndication"], iframe[src*="doubleclick"],
    .header-h1, .breadcrumb, .model-btn, .header-model-btn { display: none !important; }

    #main-warpper, .wrapper { padding-top: 0 !important; margin-top: 0 !important; }
    body { padding-top: 0 !important; }
    """

    private static func jsLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// 页面加载最开始注入：设置暗色标记 + 埋入可开关的样式节点。
    /// `css` 允许独立页换一套清理规则，默认使用首页的 cleanCSS。
    static func bootstrap(dark: Bool, clean: Bool, fontPercent: Int, css: String? = nil) -> String {
        let cssLiteral = jsLiteral(css ?? cleanCSS)
        let setDark = dark ? "true" : "false"
        let disabled = clean ? "false" : "true"
        return """
        (function () {
          try { localStorage.setItem('darkMode', '\(setDark)'); } catch (e) {}
          try {
            if (\(setDark)) { document.documentElement.classList.add('dark-model'); }
            else { document.documentElement.classList.remove('dark-model'); }
          } catch (e) {}
          function jdBoot() {
            try {
              var s = document.getElementById('jd-app-style');
              if (!s) {
                s = document.createElement('style');
                s.id = 'jd-app-style';
                (document.head || document.documentElement).appendChild(s);
              }
              s.innerHTML = \(cssLiteral);
              s.disabled = \(disabled);
            } catch (e) {}
            try {
              document.body.style.webkitTextSizeAdjust = '\(fontPercent)%';
            } catch (e) {}
          }
          try {
            if (document.documentElement) { jdBoot(); }
            else { document.addEventListener('DOMContentLoaded', jdBoot); }
          } catch (e) { document.addEventListener('DOMContentLoaded', jdBoot); }
        })();
        """
    }

    static func setDark(_ enabled: Bool) -> String {
        """
        (function () {
          try {
            localStorage.setItem('darkMode', '\(enabled ? "true" : "false")');
            if (\(enabled ? "true" : "false")) { document.documentElement.classList.add('dark-model'); }
            else { document.documentElement.classList.remove('dark-model'); }
          } catch (e) {}
        })();
        """
    }

    static func setClean(_ enabled: Bool) -> String {
        """
        (function () {
          try { document.getElementById('jd-app-style').disabled = \(enabled ? "false" : "true"); }
          catch (e) {}
        })();
        """
    }

    static func setFont(_ percent: Int) -> String {
        """
        (function () {
          try { document.body.style.webkitTextSizeAdjust = '\(percent)%'; } catch (e) {}
        })();
        """
    }

    /// 栏目页（/pic、/top ...）会带一个 h1.post-h1 大标题，与原生频道条重复。
    /// 只隐藏「标题文字恰好等于频道名」的那一个，避免误伤文章详情页的正文标题。
    static func hideDuplicateTitle() -> String {
        let names = [
            "首页", "新鲜事", "热榜", "无聊图", "随手拍", "树洞",
            "问答", "女装", "鱼塘", "日报", "大吐槽",
        ]
        let literal = (try? JSONSerialization.data(withJSONObject: names))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function () {
          try {
            var names = \(literal);
            var h = document.querySelector('main.main h1.post-h1');
            if (h && names.indexOf((h.textContent || '').trim()) !== -1) {
              h.style.display = 'none';
            }
          } catch (e) {}
        })();
        """
    }
}
