// swift-tools-version:6.0
import PackageDescription

// Glance for Mac. Source folders keep their original names; products are named Glance.
let package = Package(
    name: "Glance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glance",
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "glance-hook",
            path: "Sources/IslandHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "glance-chrome-host",
            path: "Sources/IslandChromeHost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GlanceBar",
            path: "Sources/IslandBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
