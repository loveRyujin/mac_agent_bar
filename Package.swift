// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AgentBarCore"),
        .executableTarget(
            name: "AgentBar",
            dependencies: ["AgentBarCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AgentBarCoreTests", dependencies: ["AgentBarCore"]),
    ]
)
