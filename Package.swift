// swift-tools-version: 6.0
// SwiftAgentKit — Swift-native middleware for LLM apps:
// tool calling, structured output, streaming and MCP for on-device and cloud models.

import PackageDescription

let package = Package(
    name: "SwiftAgentKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftAgentKit", targets: ["SwiftAgentKit"]),
        .executable(name: "swiftagentkit-demo", targets: ["swiftagentkit-demo"]),
    ],
    targets: [
        .target(
            name: "SwiftAgentKit",
            path: "Sources/SwiftAgentKit"
        ),
        .executableTarget(
            name: "swiftagentkit-demo",
            dependencies: ["SwiftAgentKit"],
            path: "Sources/swiftagentkit-demo"
        ),
        .testTarget(
            name: "SwiftAgentKitTests",
            dependencies: ["SwiftAgentKit"],
            path: "Tests/SwiftAgentKitTests"
        ),
    ]
)
