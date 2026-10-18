// swift-tools-version: 6.0
import PackageDescription

/// Release builds optimise for size: a UI app gains nothing measurable from -O's larger code.
let releaseForSize: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "Kore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KoreCore", targets: ["KoreCore"]),
        .executable(name: "Kore", targets: ["Kore"]),
        .executable(name: "kore-cli", targets: ["kore-cli"]),
        .executable(name: "kore-storylines", targets: ["kore-storylines"]),
        .executable(name: "kore-fake-cli", targets: ["kore-fake-cli"]),
    ],
    targets: [
        .target(name: "KoreCore", swiftSettings: releaseForSize),
        // The app's views, stores and providers; `Kore` is its launcher. Other targets in this
        // package reach its `package` declarations.
        .target(name: "KoreUI", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        .executableTarget(name: "Kore", dependencies: ["KoreUI"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // User storylines (phase 12): the engine, steps, scripted CLI and catalogue, and the app
        // with them inside. Neither is part of Kore.app.
        .target(name: "KoreStorylines", dependencies: ["KoreUI", "KoreCore"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-storylines", dependencies: ["KoreStorylines", "KoreUI"], swiftSettings: releaseForSize),
        // Plays recorded CLI sessions as `claude` / `codex` for storylines.
        .executableTarget(name: "kore-fake-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // `swift test`: Swift Testing, in the Command Line Tools (phase 12's core layer).
        .testTarget(name: "KoreCoreTests", dependencies: ["KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreUITests", dependencies: ["KoreUI", "KoreCore"]),
        .testTarget(name: "StorylineTests", dependencies: ["KoreStorylines"]),
    ]
)
