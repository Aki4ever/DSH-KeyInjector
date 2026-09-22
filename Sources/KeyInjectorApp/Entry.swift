// ==============================================================================
// 应用入口（AppKit，无 SwiftUI 依赖）
// ==============================================================================
import AppKit

@main
enum KeyInjectorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
