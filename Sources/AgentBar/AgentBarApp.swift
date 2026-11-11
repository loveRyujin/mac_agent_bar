import AgentBarCore
import SwiftUI

@main
struct AgentBarApp: App {
    var body: some Scene {
        MenuBarExtra("AgentBar", systemImage: "person.crop.circle.badge.checkmark") {
            VStack(alignment: .leading) {
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
