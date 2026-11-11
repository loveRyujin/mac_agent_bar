import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

private let databasePath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"

/// 测试用的 SQLite 连接（可读写），用来生成 fixture 数据库。
private final class TestDatabase {
    private var db: OpaquePointer?

    init(at url: URL, journalMode: String = "DELETE") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw TestDatabaseError() }
        try execute("PRAGMA journal_mode=\(journalMode)")
        try execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TestDatabaseError() }
    }

    func insert(_ items: [String: String]) throws {
        for (key, value) in items {
            let escaped = { (s: String) in s.replacingOccurrences(of: "'", with: "''") }
            try execute("INSERT INTO ItemTable (key, value) VALUES ('\(escaped(key))', '\(escaped(value))')")
        }
    }
}

private struct TestDatabaseError: Error {}

private let proPlusItems = [
    "cursorAuth/stripeMembershipType": "pro_plus",
    "cursorAuth/stripeSubscriptionStatus": "active",
    "cursorAuth/cachedEmail": "cursor-user@example.com",
    "cursorAuth/accessToken": "fake-access-token",
    "cursorAuth/refreshToken": "fake-refresh-token",
    "workbench.panel.something": "unrelated",
]

@Suite struct CursorProviderTests {
    func home(with items: [String: String], journalMode: String = "DELETE") throws -> TestHome {
        let home = try TestHome()
        let database = try TestDatabase(at: home.path(databasePath), journalMode: journalMode)
        try database.insert(items)
        return home
    }

    @Test func proPlusActive() async throws {
        let home = try home(with: proPlusItems)
        let status = try await CursorProvider(home: home.url).fetchStatus()

        #expect(status.plan == Plan(rawValue: "pro_plus", displayName: "Pro+"))
        #expect(status.state == .active)
        #expect(status.account == "cursor-user@example.com")
        #expect(status.details == [Detail("stripeSubscriptionStatus", "active")])
    }

    @Test func free() async throws {
        let home = try home(with: [
            "cursorAuth/stripeMembershipType": "free",
            "cursorAuth/cachedEmail": "free-user@example.com",
        ])
        let status = try await CursorProvider(home: home.url).fetchStatus()

        #expect(status.plan == Plan(rawValue: "free", displayName: "Free"))
        #expect(status.state == .active)
        #expect(status.details.isEmpty)
    }

    @Test func notSignedIn() async throws {
        let home = try home(with: ["workbench.panel.something": "unrelated"])
        let provider = CursorProvider(home: home.url)
        #expect(provider.isInstalled())

        let status = try await provider.fetchStatus()

        #expect(status.state == .signedOut)
        #expect(status.account == nil)
    }

    @Test func unknownPlanIsShownRaw() async throws {
        var items = proPlusItems
        items["cursorAuth/stripeMembershipType"] = "hyper_mega"
        let status = try await CursorProvider(home: try home(with: items).url).fetchStatus()

        #expect(status.plan == Plan(rawValue: "hyper_mega", displayName: "hyper_mega"))
        #expect(status.state == .active)
    }

    @Test(arguments: [
        ("trialing", SubscriptionStatus.State.trial),
        ("past_due", .unknown),
        ("canceled", .unknown),
    ])
    func subscriptionStatusMapping(raw: String, expected: SubscriptionStatus.State) async throws {
        var items = proPlusItems
        items["cursorAuth/stripeSubscriptionStatus"] = raw
        let status = try await CursorProvider(home: try home(with: items).url).fetchStatus()

        #expect(status.state == expected)
        #expect(status.details == [Detail("stripeSubscriptionStatus", raw)])
    }

    @Test func missingMembershipButSignedIn() async throws {
        let status = try await CursorProvider(home: try home(with: [
            "cursorAuth/cachedEmail": "someone@example.com",
        ]).url).fetchStatus()

        #expect(status.plan.displayName == "未知套餐")
        #expect(status.state == .unknown)
        #expect(status.account == "someone@example.com")
    }

    @Test func readsDatabaseInWALMode() async throws {
        let home = try TestHome()
        // 保持写连接打开，WAL 文件里还有未合并的数据（与 Cursor 运行时的状态相同）。
        let writer = try TestDatabase(at: home.path(databasePath), journalMode: "WAL")
        try writer.insert(proPlusItems)

        let status = try await CursorProvider(home: home.url).fetchStatus()

        #expect(status.plan.displayName == "Pro+")
        _ = writer
    }

    @Test func lockedDatabaseThrowsReadableError() async throws {
        let home = try home(with: proPlusItems)
        let locker = try TestDatabase(at: home.path(databasePath))
        try locker.execute("BEGIN EXCLUSIVE")

        await #expect(throws: ProviderError.unreadable("Cursor 数据库被占用，请稍后刷新")) {
            try await CursorProvider(home: home.url).fetchStatus()
        }
        try locker.execute("ROLLBACK")
    }

    @Test func corruptFileThrowsReadableError() async throws {
        let home = try TestHome()
        try home.write("this is not a database, just some text padding it out a little", to: databasePath)

        await #expect(throws: ProviderError.self) {
            try await CursorProvider(home: home.url).fetchStatus()
        }
    }

    @Test func doesNotModifyTheDatabase() async throws {
        let home = try home(with: proPlusItems)
        let url = home.path(databasePath)
        let before = try Data(contentsOf: url)

        _ = try await CursorProvider(home: home.url).fetchStatus()

        #expect(try Data(contentsOf: url) == before)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-journal"))
    }

    @Test func missingFileIsNotInstalled() async throws {
        let provider = CursorProvider(home: try TestHome().url)
        #expect(!provider.isInstalled())
        await #expect(throws: ProviderError.fileNotFound("~/\(databasePath)")) {
            try await provider.fetchStatus()
        }
    }

    @Test func identity() {
        let provider = CursorProvider()
        #expect(provider.id == "cursor")
        #expect(provider.displayName == "Cursor")
        #expect(provider.iconName == "cursor")
    }
}
