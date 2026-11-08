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
        .executable(name: "kore-command", targets: ["kore-command"]),
        .executable(name: "kore-storylines", targets: ["kore-storylines"]),
        .executable(name: "kore-fake-cli", targets: ["kore-fake-cli"]),
        .executable(name: "kore-power-bench", targets: ["kore-power-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c"),
    ],
    targets: [
        .target(name: "KoreCore", swiftSettings: releaseForSize),
        // The chat engine without UI: the CLIs' backends and translators, chat events, account
        // calls and the chat state that has no view code. No SwiftUI, AppKit or Combine, so a
        // headless host can build on it; nothing here imports KoreUI.
        .target(name: "src", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // The app's views and the stores they show, over `src`; `Kore` is its launcher. Other
        // targets in this package reach its `package` declarations.
        .target(
            name: "KoreUI", dependencies: ["src", "KoreCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            // mermaid.js for the diagram preview: bundled, so it never loads from the network.
            resources: [.copy("Resources/mermaid.min.js")], swiftSettings: releaseForSize),
        // The local link (`z-docs/link-protocol.md`): a companion app on the same Mac, allowed by
        // the user at a ring, follows chats and acts in them under Kore's rules. Asleep (no
        // socket, timer or observer) until then.
        .target(name: "KoreLink", dependencies: ["KoreUI", "src", "KoreCore"], swiftSettings: releaseForSize),
        .executableTarget(name: "Kore", dependencies: ["KoreUI", "KoreCore", "KoreLink"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // The `kore` command in Kore.app (Contents/Helpers/kore): the reads over Kore's agent
        // channel (`z-docs/agent-protocol.md`) and `kore mcp`; opening and `kore setup` stay the
        // zsh script's. Foundation only, so it stays small and starts fast.
        .executableTarget(name: "kore-command", swiftSettings: releaseForSize),
        // User storylines (phase 12): the engine, steps, scripted CLI and catalogue, and the app
        // with them inside. Neither is part of Kore.app.
        .target(name: "KoreStorylines", dependencies: ["KoreUI", "src", "KoreCore", "KoreLink"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-storylines", dependencies: ["KoreStorylines", "KoreUI"], swiftSettings: releaseForSize),
        // Plays recorded CLI sessions as `claude` / `codex` for storylines.
        .executableTarget(name: "kore-fake-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // Synthetic held views, without accounts, CLIs, navigation pacing or sampling timers.
        .executableTarget(name: "kore-power-bench", dependencies: ["KoreUI"], swiftSettings: releaseForSize),
        // `swift test`: Swift Testing, in the Command Line Tools (phase 12's core layer).
        .testTarget(name: "KoreCoreTests", dependencies: ["KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreUITests", dependencies: ["KoreUI", "src", "KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreLinkTests", dependencies: ["KoreLink", "KoreUI", "src", "KoreCore"]),
        .testTarget(name: "StorylineTests", dependencies: ["KoreStorylines", "KoreUI", "src", "KoreCore"]),
    ]
)
