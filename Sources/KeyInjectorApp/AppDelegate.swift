// ==============================================================================
// 应用外壳：主窗口、菜单与 WKWebView 装载
// ==============================================================================
import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridge: Bridge!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 菜单（保证 ⌘Q / ⌘W 等标准快捷键可用）

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Key 注入器",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Key 注入器",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Key 注入器",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: 窗口

    /// 允许通过环境变量固定窗口位置与尺寸，便于自动化截图台账稳定复现
    private func resolvedFrame() -> NSRect {
        let fallback = NSRect(x: 0, y: 0, width: 1240, height: 820)
        guard let raw = ProcessInfo.processInfo.environment["KEYINJECTOR_WINDOW_RECT"] else { return fallback }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return fallback }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func buildWindow() {
        let envRect = ProcessInfo.processInfo.environment["KEYINJECTOR_WINDOW_RECT"]
        let frame = resolvedFrame()
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Key 注入器"
        window.minSize = NSSize(width: 1020, height: 660)
        // 指定了 KEYINJECTOR_WINDOW_RECT 时不居中，保证自动化截图位置可复现
        if envRect == nil { window.center() }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        bridge = Bridge()
        bridge.webView = nil
        config.userContentController.add(bridge, name: "bridge")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        bridge.webView = webView
        window.contentView = webView

        loadFrontend()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 前端资源解析顺序：环境变量 → .app 内 Resources/ui → 仓库根目录 web/
    private func loadFrontend() {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["KEYINJECTOR_WEB_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("ui", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true).appendingPathComponent("web", isDirectory: true))

        for dir in candidates {
            let index = dir.appendingPathComponent("index.html")
            if fm.fileExists(atPath: index.path) {
                webView.loadFileURL(index, allowingReadAccessTo: dir)
                return
            }
        }

        let html = "<html><body style='font-family:-apple-system;padding:40px'>"
            + "<h2>找不到前端资源</h2>"
            + "<p>已尝试以下目录：</p><ul>"
            + candidates.map { "<li><code>\($0.path)</code></li>" }.joined()
            + "</ul><p>可通过环境变量 <code>KEYINJECTOR_WEB_DIR</code> 指定前端目录。</p></body></html>"
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: 导航策略：只允许本地文件，外部链接交给系统浏览器

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let dir = ProcessInfo.processInfo.environment["KEYINJECTOR_SNAPSHOT_DIR"], !dir.isEmpty {
            runSnapshotHarness(directory: dir)
        }
    }

    // MARK: 页面视觉台账快照

    /// 通过 WKWebView 自身的渲染快照生成页面图片。
    /// 之所以不用系统的 screencapture：本机未授予屏幕录制权限，且应用内快照
    /// 只包含页面内容本身，更适合作为交付台账的基准图。
    private func runSnapshotHarness(directory: String) {
        let demoPath = ProcessInfo.processInfo.environment["KEYINJECTOR_SNAPSHOT_DEMO_FILE"] ?? ""

        let steps: [(name: String, script: String, delay: Double)] = [
            ("Page_KeyInjector_Keys_Default", "window.__selectPage('keys')", 1.0),
            ("Page_KeyInjector_Keys_AddDialog", "window.__openAddKeyModal()", 1.0),
            ("Page_KeyInjector_Inject_DryRun",
             "window.__closeAddKeyModal(); window.__selectPage('inject'); window.__snapshotSetPath('\(demoPath)'); window.__snapshotPlan()", 1.8),
            ("Page_KeyInjector_Health_Default", "window.__selectPage('health')", 1.0),
            ("Page_KeyInjector_Audit_Default", "window.__selectPage('audit')", 1.0),
            ("Page_KeyInjector_Settings_Default", "window.__selectPage('settings')", 1.0)
        ]

        let dirURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        func runStep(_ index: Int) {
            guard index < steps.count else {
                FileHandle.standardError.write(Data("SNAPSHOT_DONE\n".utf8))
                return
            }
            let step = steps[index]
            webView.evaluateJavaScript(step.script) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                    guard let self else { return }
                    self.webView.takeSnapshot(with: nil) { image, _ in
                        if let image,
                           let tiff = image.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            let url = dirURL.appendingPathComponent("\(step.name).png")
                            try? png.write(to: url)
                            print("SNAPSHOT_WRITTEN \(url.path) \(png.count)")
                        }
                        runStep(index + 1)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { runStep(0) }
    }
}
