// swift-tools-version:6.0
import PackageDescription

// Glance for Mac. Source folders keep their original names; products are named Glance.
let package = Package(
    name: "Glance",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates (signed appcast, EdDSA). Pinned so every build uses the same framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Glance",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is copied into Contents/Frameworks by build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
