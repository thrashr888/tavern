// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tavern",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Tavern", targets: ["TavernApp"]),
        .library(name: "TavernCore", targets: ["TavernCore"]),
    ],
    targets: [
        // Models, event store and source adapters. No UI, so it is testable with `swift test`.
        .target(
            name: "TavernCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI shell. Run with `swift run Tavern` on the M5.
        .executableTarget(
            name: "TavernApp",
            dependencies: ["TavernCore"],
            // AppIcon.png is rendered from art/AppIcon.svg; set as the Dock icon at launch.
            // Party art isn't bundled: portrait.* and avatars/<id>.* come from Application Support.
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "TavernCoreTests",
            dependencies: ["TavernCore"]
        ),
    ]
)
