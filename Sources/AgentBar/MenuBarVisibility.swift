import AppKit

/// 状态栏图标是否显示。
///
/// 只有一个 `MenuBarExtra` 的 SwiftUI 应用在图标被隐藏时（⌘ 拖出状态栏，或被控制中心隐藏）会直接退出，
/// 之后每次启动都立即退出，看起来像坏了。所以这里用 `MenuBarExtra(isInserted:)` 自己管理：
/// 图标被隐藏时应用继续运行；用户手动打开应用时把图标显示回来；
/// 若被系统隐藏、显示不回来，就提示用户去“系统设置 → 菜单栏”打开。
@MainActor
enum MenuBarVisibility {
    /// `@AppStorage` 和这里共用的键。
    static let key = "showInMenuBar"

    /// 显示图标；过一会儿检查是否又被系统隐藏，是的话提示用户。
    static func show() {
        UserDefaults.standard.set(true, forKey: key)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !UserDefaults.standard.bool(forKey: key) {
                alertHiddenBySystem()
            }
        }
    }

    private static func alertHiddenBySystem() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AgentBar 的状态栏图标被系统隐藏了"
        alert.informativeText = "AgentBar 仍在运行。请在“系统设置 → 菜单栏”中允许 AgentBar 显示在菜单栏里。"
        alert.addButton(withTitle: "打开菜单栏设置")
        alert.addButton(withTitle: "退出 AgentBar")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

/// 处理“再次打开应用”和启动方式。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 开机自启时尊重用户隐藏图标的选择；手动打开时把图标显示出来
        if !Self.launchedAsLoginItem {
            MainActor.assumeIsolated { MenuBarVisibility.show() }
        }
    }

    /// 应用已在运行时再次打开（Finder、启动台、`open`）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MenuBarVisibility.show() }
        return false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
