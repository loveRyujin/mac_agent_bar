import AppKit

/// 用代码打开状态栏的下拉面板。系统没有公开 API 能打开 `MenuBarExtra`，
/// 这里在应用自己的窗口中找到状态栏按钮并模拟点击；找不到时返回 false。
@MainActor
enum StatusItemPanel {
    @discardableResult
    static func open() -> Bool {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = findButton(in: window.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}
