// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoreEase",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "coreease-cli", targets: ["CoreEaseCLI"]),
        .executable(name: "CoreEaseApp", targets: ["CoreEaseApp"]),
        .library(name: "CoreEaseKit", targets: ["CoreEaseKit"])
    ],
    targets: [
        .target(
            name: "CoreEaseKit",
            path: "Sources/CoreEaseKit"
        ),
        .executableTarget(
            name: "CoreEaseCLI",
            dependencies: ["CoreEaseKit"],
            path: "Sources/CoreEaseCLI"
        ),
        .executableTarget(
            name: "CoreEaseApp",
            dependencies: ["CoreEaseKit"],
            path: "Sources/CoreEaseApp"
        ),
        .testTarget(
            name: "CoreEaseKitTests",
            dependencies: ["CoreEaseKit"],
            path: "Tests/CoreEaseKitTests"
        )
    ]
)
