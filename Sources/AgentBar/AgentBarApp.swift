import AgentBarCore
import SwiftUI

@main
struct AgentBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            // 临时界面：用于确认图标着色，工单 06 会替换成正式的面板。
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    AgentIconView(iconName: "claude", displayName: "Claude Code", size: 20)
                    AgentIconView(iconName: "openai", displayName: "Codex", size: 20)
                    AgentIconView(iconName: "cursor", displayName: "Cursor", size: 20)
                    AgentIconView(iconName: nil, displayName: "Fallback", size: 20)
                }
                Divider()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding()
        } label: {
            AgentIconView(iconName: "claude", displayName: "Claude Code")
        }
        .menuBarExtraStyle(.window)
    }
}
