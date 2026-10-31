// swift-tools-version: 6.2
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
        .executable(name: "kore-phone", targets: ["kore-phone"]),
        .executable(name: "kore-storylines", targets: ["kore-storylines"]),
        .executable(name: "kore-fake-cli", targets: ["kore-fake-cli"]),
        .executable(name: "kore-power-bench", targets: ["kore-power-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c"),
    ],
    targets: [
        .target(name: "KoreCore", swiftSettings: releaseForSize),
        // The phone remote's host side apart from the app: the wire protocol, sessions, sync,
        // attention and the policy. No views and no app state; KoreUI bridges Kore to it.
        .target(name: "KoreRemote", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // The app's views, stores and providers; `Kore` is its launcher. Other targets in this
        // package reach its `package` declarations.
        .target(
            name: "KoreUI", dependencies: ["KoreCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            // mermaid.js for the diagram preview: bundled, so it never loads from the network.
            resources: [.copy("Resources/mermaid.min.js")], swiftSettings: releaseForSize),
        // The phone remote's bridge to Kore: its host, sync, actions and Mac UI. Only Kore Phone
        // has it; Kore itself carries none of it.
        .target(name: "KorePhone", dependencies: ["KoreUI", "KoreCore", "KoreRemote"], swiftSettings: releaseForSize),
        .executableTarget(name: "Kore", dependencies: ["KoreUI", "KoreCore"], swiftSettings: releaseForSize),
        // Kore Phone: the same app with the phone remote installed at launch.
        .executableTarget(
            name: "kore-phone", dependencies: ["KorePhone", "KoreUI", "KoreCore"], path: "Sources/KorePhoneApp",
            swiftSettings: releaseForSize),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // User storylines (phase 12): the engine, steps, scripted CLI and catalogue, and the app
        // with them inside. Neither is part of Kore.app.
        .target(name: "KoreStorylines", dependencies: ["KoreUI", "KoreCore", "KoreRemote", "KorePhone"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-storylines", dependencies: ["KoreStorylines", "KoreUI"], swiftSettings: releaseForSize),
        // Plays recorded CLI sessions as `claude` / `codex` for storylines.
        .executableTarget(name: "kore-fake-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // Synthetic held views, without accounts, CLIs, navigation pacing or sampling timers.
        .executableTarget(name: "kore-power-bench", dependencies: ["KoreUI"], swiftSettings: releaseForSize),
        // `swift test`: Swift Testing, in the Command Line Tools (phase 12's core layer).
        .testTarget(name: "KoreCoreTests", dependencies: ["KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreUITests", dependencies: ["KoreUI", "KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreRemoteTests", dependencies: ["KoreRemote"]),
        .testTarget(name: "KorePhoneTests", dependencies: ["KorePhone", "KoreRemote", "KoreUI", "KoreCore"]),
        .testTarget(name: "StorylineTests", dependencies: ["KoreStorylines", "KoreUI", "KoreCore"]),
    ]
)
