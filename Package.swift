// swift-tools-version:5.9
import PackageDescription

// VaporwatchCore is Foundation-only (no AppKit/SwiftUI) so it builds with Swift on Linux and
// Windows too; the menu-bar app target only exists when the manifest is evaluated on macOS.
var products: [Product] = [.library(name: "VaporwatchCore", targets: ["VaporwatchCore"])]
var targets: [Target] = [
    .target(name: "VaporwatchCore", path: "Sources/VaporwatchCore"),
    .testTarget(name: "VaporwatchCoreTests", dependencies: ["VaporwatchCore"], path: "Tests/VaporwatchCoreTests"),
]
#if os(macOS)
products.append(.executable(name: "Vaporwatch", targets: ["Vaporwatch"]))
targets.append(.executableTarget(name: "Vaporwatch", dependencies: ["VaporwatchCore"], path: "Sources/Vaporwatch"))
#endif

let package = Package(
    name: "Vaporwatch",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
