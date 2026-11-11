import Foundation
import Testing
@testable import AgentBarCore

private struct FakeProvider: Provider {
    enum Behavior: Sendable {
        case succeed(SubscriptionStatus)
        case fail(String)
    }

    let id: String
    var displayName: String { id }
    let installed: Bool
    let behavior: Behavior

    func isInstalled() -> Bool { installed }

    func fetchStatus() async throws -> SubscriptionStatus {
        switch behavior {
        case .succeed(let status): return status
        case .fail(let message): throw ProviderError.unreadable(message)
        }
    }
}

private let sampleStatus = SubscriptionStatus(
    plan: Plan(rawValue: "plus", displayName: "Plus"),
    state: .active,
    account: "someone@example.com"
)

@Suite struct ProviderRegistryTests {
    @Test func refreshAllCollectsSuccessAndFailureAndSkipsUninstalled() async {
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: "ok", installed: true, behavior: .succeed(sampleStatus)),
            FakeProvider(id: "missing", installed: false, behavior: .succeed(sampleStatus)),
            FakeProvider(id: "broken", installed: true, behavior: .fail("坏了")),
        ])

        let results = await registry.refreshAll()

        #expect(results.map(\.provider.id) == ["ok", "broken"])
        #expect(results[0].outcome == .success(sampleStatus))
        #expect(results[1].outcome == .failure(ProviderError.unreadable("坏了")))
    }

    @Test func refreshAllKeepsRegistryOrderRegardlessOfCompletionOrder() async {
        let ids = (0..<20).map { "p\($0)" }
        let registry = ProviderRegistry(providers: ids.map {
            FakeProvider(id: $0, installed: true, behavior: .succeed(sampleStatus))
        })

        let results = await registry.refreshAll()

        #expect(results.map(\.provider.id) == ids)
    }

    @Test func providerErrorsHaveReadableMessages() {
        #expect(ProviderError.fileNotFound("~/.codex/auth.json").message == "找不到 ~/.codex/auth.json")
        #expect(ProviderError.unreadable("数据库被锁定").message == "数据库被锁定")
    }

    @Test func unknownErrorsAreWrappedWithTheirDescription() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        struct ThrowingProvider: Provider {
            var id: String { "throwing" }
            var displayName: String { "Throwing" }
            func isInstalled() -> Bool { true }
            func fetchStatus() async throws -> SubscriptionStatus { throw Boom() }
        }

        let results = await ProviderRegistry(providers: [ThrowingProvider()]).refreshAll()

        guard case .failure(let error) = results.first?.outcome else {
            Issue.record("应当失败")
            return
        }
        #expect(error.message.contains("boom"))
    }
}

@Suite struct TestHomeTests {
    @Test func copiesFixtureIncludingHiddenFiles() throws {
        let home = try TestHome(fixture: "_sample")
        let contents = try String(contentsOf: home.path(".hidden/file.txt"), encoding: .utf8)
        #expect(contents == "hello\n")
    }
}
