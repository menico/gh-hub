// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HubKit", targets: ["HubKit"]),
        .executable(name: "gh-hub", targets: ["Hub"]),
    ],
    dependencies: [
        // The built-in terminal. Kept behind TerminalPane so libghostty can replace it later.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.2"),
    ],
    targets: [
        // Everything that works without a window: the gh CLI contract, the
        // GitHub API client, the models and the workflow file parser.
        .target(name: "HubKit", path: "Sources/HubKit"),
        .executableTarget(
            name: "Hub",
            dependencies: ["HubKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Hub",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit"], path: "Tests/HubKitTests"),
    ],
    swiftLanguageVersions: [.v5]
)
