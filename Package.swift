// swift-tools-version:5.9
import PackageDescription

// SteamwatchCore is Foundation-only (no AppKit/SwiftUI) so it builds with Swift on Linux and
// Windows too; the menu-bar app target only exists when the manifest is evaluated on macOS.
var products: [Product] = [.library(name: "SteamwatchCore", targets: ["SteamwatchCore"])]
var targets: [Target] = [
    .target(name: "SteamwatchCore", path: "Sources/SteamwatchCore"),
    .testTarget(name: "SteamwatchCoreTests", dependencies: ["SteamwatchCore"], path: "Tests/SteamwatchCoreTests"),
]
#if os(macOS)
products.append(.executable(name: "Steamwatch", targets: ["Steamwatch"]))
targets.append(.executableTarget(name: "Steamwatch", dependencies: ["SteamwatchCore"], path: "Sources/Steamwatch"))
#endif

let package = Package(
    name: "Steamwatch",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
