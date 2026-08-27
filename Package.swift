// swift-tools-version: 6.0
import PackageDescription

// AgentHUDCore holds the whole app; AgentHUDMain is only the entry point, so
// the tests can link the code without linking an executable's `main`.
let package = Package(
    name: "agent-hud",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agent-hud", targets: ["AgentHUDMain"])
    ],
    targets: [
        .executableTarget(name: "AgentHUDMain", dependencies: ["AgentHUDCore"]),
        .target(name: "AgentHUDCore"),
        .testTarget(name: "AgentHUDCoreTests", dependencies: ["AgentHUDCore"]),
    ],
    swiftLanguageModes: [.v5]
)
