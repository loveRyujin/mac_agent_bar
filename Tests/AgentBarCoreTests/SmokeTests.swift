import Testing
@testable import AgentBarCore

@Test func versionIsSet() {
    #expect(!AgentBarCore.version.isEmpty)
}
