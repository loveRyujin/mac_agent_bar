import Foundation
import Testing
@testable import AgentBarCore

@Suite struct PreferencesMigrationTests {
    /// 测试期间持有这些对象，结束时自动清理。
    private let pool = TestDefaultsPool()

    func makeDefaults() -> UserDefaults {
        pool.make()
    }

    @Test func copiesKnownKeysOnce() {
        let old = makeDefaults(), new = makeDefaults()
        old.set(Data("{\"hideEmail\":true}".utf8), forKey: "settings")
        old.set("cursor", forKey: "selectedProviderID")
        old.set(Data("{}".utf8), forKey: "notificationLedger")
        old.set(true, forKey: "launchAtLoginDefaultApplied")
        old.set(0, forKey: "NSStatusItem VisibleCC Item-0")

        #expect(PreferencesMigration.migrate(from: old, to: new) == true)

        #expect(new.data(forKey: "settings") == Data("{\"hideEmail\":true}".utf8))
        #expect(new.string(forKey: "selectedProviderID") == "cursor")
        #expect(new.data(forKey: "notificationLedger") == Data("{}".utf8))
        // 开机自启要在新 id 下重新注册；状态栏可见性是旧 id 的问题来源，都不复制
        #expect(new.object(forKey: "launchAtLoginDefaultApplied") == nil)
        #expect(new.object(forKey: "NSStatusItem VisibleCC Item-0") == nil)

        // 只迁移一次：之后旧数据再变也不覆盖
        old.set("codex", forKey: "selectedProviderID")
        #expect(PreferencesMigration.migrate(from: old, to: new) == false)
        #expect(new.string(forKey: "selectedProviderID") == "cursor")
    }

    @Test func doesNotOverwriteExistingData() {
        let old = makeDefaults(), new = makeDefaults()
        old.set("cursor", forKey: "selectedProviderID")
        new.set(Data("{}".utf8), forKey: "settings")

        #expect(PreferencesMigration.migrate(from: old, to: new) == false)
        #expect(new.string(forKey: "selectedProviderID") == nil)
    }

    @Test func nothingToMigrate() {
        #expect(PreferencesMigration.migrate(from: makeDefaults(), to: makeDefaults()) == false)
    }
}

/// 一个测试里要多个独立 UserDefaults 时，统一持有、统一清理。
final class TestDefaultsPool {
    private var items: [TestDefaults] = []

    func make() -> UserDefaults {
        let item = TestDefaults()
        items.append(item)
        return item.defaults
    }
}
