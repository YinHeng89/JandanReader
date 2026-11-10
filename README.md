# 煎蛋 · JandanReader

用 **SwiftUI + WKWebView** 给 [煎蛋网](https://jandan.net/) 做的 iOS 阅读客户端。原生外壳负责导航、设置与阅读体验，网页内容仍由站点实时加载。

> **非官方客户端**，与煎蛋网无任何关联。内容版权归原站及原作者所有，本项目不含任何内容抓取、离线缓存或再分发逻辑，**仅供个人学习与自用侧载**。纯 WebView 封装很难通过 App Store 4.2「最低限度功能」审核，因此不计划上架。

仓库：https://github.com/YinHeng89/JandanReader.git

## 效果

| 首页（浅色） | 夜间模式 | 用户中心（独立页） |
| :---: | :---: | :---: |
| <img src="docs/screenshots/home.png" width="230" alt="首页"> | <img src="docs/screenshots/dark.png" width="230" alt="夜间模式"> | <img src="docs/screenshots/account.png" width="230" alt="用户中心"> |

## 功能

**原生外壳**

- 10 个频道做成横向原生标签条：首页 / 热榜 / 无聊图 / 随手拍 / 树洞 / 问答 / 女装 / 鱼塘 / 日报 / 大吐槽。每个频道一个独立 `WKWebView`，懒加载，切走再切回保留滚动位置与浏览栈；再点当前标签回到该频道首页。
- 顶栏：用户中心、阅读历史、夜间模式、设置；底栏：后退 / 前进 / 刷新 / 回频道首页 / 系统分享 / 用 Safari 打开。
- 下拉刷新、加载进度条、失败重试卡片；`NSURLErrorCancelled (-999)` 属于正常打断，不会误报「页面加载失败」。
- 自建左边缘返回手势（原因见「实现要点」）。
- 阅读历史：只记录内容页（`/xxx/数字`），本地 `UserDefaults` 保存，上限 80 条。

**阅读体验**

- 纯净阅读：注入 CSS 隐藏站点导航、侧栏、页脚、广告位与推广图，重排移动端标题和评论数徽标；可在设置里一键关闭看完整网页。
- 夜间模式：直接复用站点自带的 `localStorage['darkMode']` 与 `<html class="dark-model">`，配色跟原站一致。
- 正文字号 90%–130% 可调；可清除网页缓存（保留登录 Cookie）。

**账户与链接**

- 用户中心 / 消息通知 / 订阅会员在独立全屏页打开（原生顶栏 + 独立 WebView），不寄生在频道页里，频道条焦点不会错位；两套 WebView 共享默认 `WKWebsiteDataStore`，登录态互通。
- 广告域名（含 iframe 自动跳转）直接取消，不弹系统浏览器；`target="_blank"` 在当前页打开；只有用户主动点击的站外链接才交给 Safari。

## 实现要点

| 问题 | 做法 |
| --- | --- |
| 频道切换点了没反应 / 画面不换 | SwiftUI 复用 `UIViewRepresentable` 时只走 `updateUIView`，由 `WebHostView.attach()` 换挂新频道的 WebView；`selectChannel` 必须**先** `router.ensure(channel)` 建好 store **再**改选中态，否则 SwiftUI 事务内发布 `objectWillChange` 会被丢弃。 |
| 切回浅色后手势返回闪深色 | 系统 `allowsBackForwardNavigationGestures` 在过渡期间显示的是历史条目缓存位图，改不到也刷不新。主频道关掉系统手势，改成 `UIScreenEdgePanGestureRecognizer` 接管：过渡层用**当前 live 页面的实时快照 + 当前主题色底**，与旧位图彻底无关。 |
| 页面生命周期内主题跑偏 | 暗色唯一真相源是 `localStorage['darkMode']`；`atDocumentStart` 脚本只读不写并挂 `MutationObserver`，`didStartProvisionalNavigation` / `didCommit` / `didFinish` 各同步一次，覆盖 bfcache 恢复。 |
| 设置页、历史、顶栏入口行为不一致 | 功能页判定只放 `AccountRoute.isAccount()` 一处，所有原生入口统一走 `WebRouter.open()` 分发；`/new/forum`（鱼塘）、`/new/daily`（日报）属于内容频道，特意排除。 |

## 目录结构

```
JandanReader/
├── project.yml                     # XcodeGen 工程定义
├── JandanReader.xcodeproj/          # 已随仓库提交，clone 后可直接打开
├── JandanReader/
│   ├── JandanReaderApp.swift       # @main，注入 settings / history / router
│   ├── ContentView.swift           # 顶栏 + 频道条 + 进度条 + 底栏 + 各类 sheet
│   ├── Info.plist                  # XcodeGen 生成，随工程提交
│   ├── Assets.xcassets/            # AppIcon / AccentColor
│   ├── Models/
│   │   ├── Channel.swift           # 频道定义与 URL
│   │   ├── AppSettings.swift       # 设置持久化
│   │   ├── HistoryStore.swift      # 阅读历史
│   │   ├── AccountRoute.swift      # 功能页 URL 判定与标题
│   │   └── ViewState.swift         # @StateObject 状态容器（见下方备注）
│   ├── Web/
│   │   ├── WebRouter.swift         # 每频道一个 WebStore + 统一 URL 分发
│   │   ├── WebStore.swift          # 频道 WebView、导航代理、广告拦截、缓存清理
│   │   ├── WebViewContainer.swift  # WebHostView：换挂 + 自建返回手势
│   │   ├── AccountWebStore.swift   # 功能页独立 WebView
│   │   └── PageScripts.swift       # 注入 CSS / JS（纯净、暗色、字号、去重标题）
│   └── Views/                      # Settings / Account / History / Activity / Components
└── docs/screenshots/               # README 截图
```

## 快速开始

**环境**：macOS + Xcode（本项目在 Xcode 27.2 下验证）、iOS 17.0+、Swift 5.10、iPhone / iPad；[XcodeGen](https://github.com/yonaskolb/XcodeGen) 用于从 `project.yml` 重新生成工程。

```bash
git clone https://github.com/YinHeng89/JandanReader.git
cd JandanReader
open JandanReader.xcodeproj        # 工程已提交，可直接 ⌘R 跑模拟器
```

只有改动 `project.yml` 后才需要重新生成：

```bash
brew install xcodegen              # 首次
xcodegen generate
```

**真机前必改**：`project.yml` 里的 `DEVELOPMENT_TEAM: QQ9F8WHWZQ` 和 `PRODUCT_BUNDLE_IDENTIFIER: com.yinheng.JandanReader` 是作者本人的配置。clone 后请改成自己的 Team ID 与唯一 bundle id，再 `xcodegen generate`，否则真机签名会失败。

## 命令行编译与侧载

```bash
# 模拟器
xcodebuild -project JandanReader.xcodeproj -scheme JandanReader \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build

# 真机 Release（不签名）
xcodebuild -project JandanReader.xcodeproj -scheme JandanReader \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO build

# 打未签名 ipa
mkdir -p build-device/Payload
cp -R build-device/Build/Products/Release-iphoneos/JandanReader.app build-device/Payload/
(cd build-device && zip -qr JandanReader-unsigned.ipa Payload)
```

`build/`、`build-device/`、`*.ipa` 已在 `.gitignore` 中忽略。安装方式：

1. **Xcode**：登录自己的 Apple ID，选真机直接 Run（个人免费签名，证书 7 天有效）。
2. **SideStore / AltStore**：把 `JandanReader-unsigned.ipa` 导入后用自己 Apple ID 重签名安装。

未签名 ipa 不能直接装到设备上。

## 兼容性与已知限制

- Xcode 27.2 编译真机 arm64 时，SwiftUI `@State` 宏插件会报 `malformed response`（模拟器正常），因此 UI 状态统一用 `@StateObject` + `@Published` 容器（`Models/ViewState.swift`）规避。
- 纯净模式与夜间模式依赖站点现有 DOM / CSS 和 `localStorage['darkMode']`，**站点改版后需要同步更新** `PageScripts.cleanCSS` 和相关选择器。
- 主界面 `ContentView` 尚未用 `@ObservedObject` 订阅 `WebStore`，进度条、前进/后退可用态在部分场景下不会实时刷新。
- 用户中心独立页仍使用系统返回手势，未纳入主界面那套实时快照过渡；自建边缘手势的手感还需真机实测确认。
- 登录态依赖默认 `WKWebsiteDataStore`，没有多账号、退出登录、离线阅读或推送。
- `Info.plist` 开启了 `NSAllowsArbitraryLoadsInWebContent`，因为站点仍存在 HTTP 资源。

## 迁移备注

仓库现位于 `~/Documents/GitHub/JandanReader`（origin 见顶部）。`JandanReader.xcodeproj` 已按新位置重新生成，工程内全部为相对路径、无旧目录残留，clone 到任意路径都能编译；旧的 `preview/` 截图与 ipa 不属于仓库内容，README 用到的三张截图已收进 `docs/screenshots/`。

## 声明

本项目为个人自用的非官方客户端，不提供任何内容服务，不对站点可用性、内容准确性或账号安全负责。请勿用于商业用途或公开分发。
