import Foundation

/// 测试用的独立 UserDefaults。对象释放时删除这个域和它在 ~/Library/Preferences 里的 plist，
/// 避免每跑一次测试就留下一个文件。测试期间要持有这个对象。
final class TestDefaults {
    let suiteName = "AgentBarTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
