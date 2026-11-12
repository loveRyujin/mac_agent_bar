import AppKit
import SwiftUI

/// 设置窗口。不用 SwiftUI 的 `Settings` 场景：macOS 13 上只能靠私有的 `showSettingsWindow:` 打开，
/// 而它在 macOS 14 起失效，替代品 `SettingsLink` 又要求 macOS 14。这里自己管理一个 NSWindow。
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// 打开（或重新置前）设置窗口。应用没有 Dock 图标，需要先把自己激活，窗口才会出现在最前面。
    static func show(model: AppModel) {
        if window == nil {
            let window = ClosableWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "AgentBar 设置"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 应用没有菜单栏，⌘W 默认不会关闭窗口，这里自己处理。
private final class ClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
