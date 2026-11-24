import Foundation
import Testing
@testable import AgentBarCore

private let root = ".config/agentbar/plugins"

private func writePlugin(_ id: String, in home: TestHome, script: String = "echo '{}'", name: String = "Example") throws {
    try home.write(#"{"apiVersion":1,"id":"\#(id)","name":"\#(name)","command":["./status"]}"#, to: "\(root)/\(id)/plugin.json")
    try home.write("#!/bin/sh\n" + script, to: "\(root)/\(id)/status")
}

@Suite struct PluginFingerprintTests {
    @Test func stableForSameContent() throws {
        let home = try TestHome()
        try writePlugin("a", in: home)
        let directory = home.path("\(root)/a")
        #expect(PluginFingerprint.compute(directory) == PluginFingerprint.compute(directory))
        #expect(PluginFingerprint.compute(directory).count == 64)
    }

    @Test func changesWhenAnyFileChanges() throws {
        let home = try TestHome()
        try writePlugin("a", in: home)
        let directory = home.path("\(root)/a")
        let original = PluginFingerprint.compute(directory)

        try home.write("#!/bin/sh\necho changed", to: "\(root)/a/status")
        let edited = PluginFingerprint.compute(directory)
        #expect(edited != original)

        try home.write("print(1)", to: "\(root)/a/lib/helper.py")
        #expect(PluginFingerprint.compute(directory) != edited)
    }

    @Test func renamingAFileChangesIt() throws {
        let home = try TestHome()
        try home.write("x", to: "\(root)/a/one")
        let before = PluginFingerprint.compute(home.path("\(root)/a"))
        try FileManager.default.moveItem(at: home.path("\(root)/a/one"), to: home.path("\(root)/a/two"))
        #expect(PluginFingerprint.compute(home.path("\(root)/a")) != before)
    }

    @Test func ignoresHiddenFiles() throws {
        let home = try TestHome()
        try writePlugin("a", in: home)
        let before = PluginFingerprint.compute(home.path("\(root)/a"))
        try home.write("finder junk", to: "\(root)/a/.DS_Store")
        try home.write("cache", to: "\(root)/a/.cache/x")
        #expect(PluginFingerprint.compute(home.path("\(root)/a")) == before)
    }

    @Test func sameContentInDifferentFoldersMatches() throws {
        let home = try TestHome()
        try writePlugin("a", in: home)
        let other = try TestHome()
        try writePlugin("a", in: other)
        #expect(PluginFingerprint.compute(home.path("\(root)/a")) == PluginFingerprint.compute(other.path("\(root)/a")))
    }
}

@Suite struct PluginCatalogTests {
    @Test func states() throws {
        let home = try TestHome()
        try writePlugin("approved", in: home)
        try writePlugin("changed", in: home)
        try writePlugin("fresh", in: home)
        try home.write("{}", to: "\(root)/broken/plugin.json")

        let approved = PluginFingerprint.compute(home.path("\(root)/approved"))
        let trusted = ["approved": approved, "changed": "stale-fingerprint", "gone": "x"]
        let items = PluginCatalog.load(home: home.url, reservedIDs: [], trusted: trusted)

        #expect(items.map(\.id) == ["approved", "broken", "changed", "fresh"])
        #expect(items.map(\.state) == [
            .enabled, .invalid("apiVersion：缺少该字段"), .needsApproval(changed: true), .needsApproval(changed: false),
        ])
        #expect(items[0].fingerprint == approved)
        #expect(items[0].manifest?.name == "Example")
        #expect(items[1].manifest == nil)
    }

    @Test func enabledProviders() throws {
        let home = try TestHome()
        try writePlugin("a", in: home, name: "Agent A")
        try writePlugin("b", in: home)
        let trusted = ["a": PluginFingerprint.compute(home.path("\(root)/a"))]
        let items = PluginCatalog.load(home: home.url, reservedIDs: [], trusted: trusted)

        let providers = PluginCatalog.enabledProviders(items, home: home.url)
        #expect(providers.map(\.id) == ["a"])
        #expect(providers.first?.displayName == "Agent A")
    }
}

@Suite struct PluginRegistryTests {
    @Test func pluginsComeAfterBuiltIns() throws {
        let home = try TestHome()
        try writePlugin("my-agent", in: home)
        let manifest = PluginManifest(id: "my-agent", name: "Mine", command: ["./status"])
        let plugin = PluginProvider(manifest: manifest, directory: home.path("\(root)/my-agent"), home: home.url)

        let registry = ProviderRegistry.standard(
            settings: AppSettings(), cursorUsage: nil, mmx: MmxClient(), plugins: [plugin])

        #expect(registry.providers.map(\.id).suffix(2) == ["mmx", "my-agent"])
        #expect(ProviderRegistry.builtInIDs.count == registry.providers.count - 1)
    }

    @Test func pluginIcon() throws {
        let home = try TestHome()
        try writePlugin("a", in: home)
        let manifest = PluginManifest(id: "a", name: "A", command: ["./status"])
        let provider = PluginProvider(manifest: manifest, directory: home.path("\(root)/a"), home: home.url)
        #expect(provider.iconURL == nil)

        try home.write("<svg/>", to: "\(root)/a/icon.svg")
        #expect(provider.iconURL?.lastPathComponent == "icon.svg")
    }

    @Test func trustedPluginsSurviveSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.trustedPlugins = ["a": "abc"]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.trustedPlugins == ["a": "abc"])

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideEmail":true}"#.utf8))
        #expect(legacy.trustedPlugins.isEmpty)
    }
}
