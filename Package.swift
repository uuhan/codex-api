// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAPI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexProxyCore", targets: ["CodexProxyCore"]),
        .executable(name: "CodexAPI", targets: ["CodexProxyApp"])
    ],
    targets: [
        .target(
            name: "CodexProxyCore",
            path: "Sources/CodexProxyCore"
        ),
        .executableTarget(
            name: "CodexProxyApp",
            dependencies: ["CodexProxyCore"],
            path: "Sources/CodexProxyApp"
        ),
        .testTarget(
            name: "CodexProxyCoreTests",
            dependencies: ["CodexProxyCore"],
            path: "Tests/CodexProxyCoreTests"
        )
    ]
)

