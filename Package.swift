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
        .executable(name: "kore-host", targets: ["kore-host"]),
        .executable(name: "kore-command", targets: ["kore-command"]),
        .executable(name: "kore-storylines", targets: ["kore-storylines"]),
        .executable(name: "kore-fake-cli", targets: ["kore-fake-cli"]),
        .executable(name: "kore-power-bench", targets: ["kore-power-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c"),
        // CryptoKit's API off macOS, for kore-host on Linux only.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "KoreCore", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
            swiftSettings: releaseForSize),
        // The chat engine without UI: the CLIs' backends and translators, chat events, account
        // calls and the chat state that has no view code. No SwiftUI, AppKit or Combine, so a
        // headless host can build on it; nothing here imports KoreUI.
        .target(name: "src", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // The app's views and the stores they show, over `src`; `Kore` is its launcher. Other
        // targets in this package reach its `package` declarations.
        .target(
            name: "KoreUI", dependencies: ["src", "HostClient", "KoreCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            // mermaid.js for the diagram preview: bundled, so it never loads from the network.
            resources: [.copy("Resources/mermaid.min.js")], swiftSettings: releaseForSize),
        // The local link (`z-docs/link-protocol.md`): a companion app on the same Mac, allowed by
        // the user at a ring, follows chats and acts in them under Kore's rules. Asleep (no
        // socket, timer or observer) until then.
        // The link's protocol: wire types, framing, the HMAC handshake, policy and the projector,
        // over `src`. No UI and no Mac-only parts, so a host without the app can serve it.
        .target(
            name: "LinkProtocol",
            dependencies: ["src", "KoreCore", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
            swiftSettings: releaseForSize),
        // A Mac window's chats on a box (`kore-host` over SSH): the transport, the link client, the
        // local copy per chat, and the chat backend that runs a `Chat` through the link. No UI;
        // KoreUI holds the one seam. Asleep until a window on a box opens.
        .target(name: "HostClient", dependencies: ["src", "LinkProtocol", "KoreCore"], swiftSettings: releaseForSize),
        .target(name: "KoreLink", dependencies: ["KoreUI", "LinkProtocol", "src", "KoreCore"], swiftSettings: releaseForSize),
        // kore-host: Kore's chats on a headless machine (phase 17), served over the link. It
        // never links KoreUI or KoreLink, and the Mac app never links it.
        // `VERSION` links to the package's own: the version kore-host says (`--version`, the welcome).
        .target(
            name: "KoreHost", dependencies: ["src", "LinkProtocol", "KoreCore", "KoreHostSys"], resources: [.embedInCode("VERSION")],
            swiftSettings: releaseForSize),
        // kore-host's one Linux call Swift can't make (a variadic one): empty on macOS.
        .target(name: "KoreHostSys"),
        .executableTarget(name: "kore-host", dependencies: ["KoreHost", "LinkProtocol"], swiftSettings: releaseForSize),
        .executableTarget(name: "Kore", dependencies: ["KoreUI", "KoreCore", "KoreLink"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // The `kore` command in Kore.app (Contents/Helpers/kore): the reads over Kore's agent
        // channel (`z-docs/agent-protocol.md`) and `kore mcp`; opening and `kore setup` stay the
        // zsh script's. Foundation only, so it stays small and starts fast.
        .executableTarget(name: "kore-command", dependencies: ["AgentTools"], swiftSettings: releaseForSize),
        // The `kore_app` tools as an MCP server lists them, and the stdio server: one list for
        // `kore mcp` on the Mac and `kore-host mcp` on a box. Foundation only.
        .target(name: "AgentTools", swiftSettings: releaseForSize),
        // User storylines (phase 12): the engine, steps, scripted CLI and catalogue, and the app
        // with them inside. Neither is part of Kore.app.
        .target(name: "KoreStorylines", dependencies: ["KoreUI", "src", "KoreCore", "KoreLink", "LinkProtocol"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-storylines", dependencies: ["KoreStorylines", "KoreUI"], swiftSettings: releaseForSize),
        // Plays recorded CLI sessions as `claude` / `codex` for storylines.
        .executableTarget(name: "kore-fake-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        // Synthetic held views, without accounts, CLIs, navigation pacing or sampling timers.
        .executableTarget(name: "kore-power-bench", dependencies: ["KoreUI"], swiftSettings: releaseForSize),
        // `swift test`: Swift Testing, in the Command Line Tools (phase 12's core layer).
        .testTarget(name: "KoreCoreTests", dependencies: ["KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreUITests", dependencies: ["KoreUI", "src", "KoreCore", "kore-fake-cli"]),
        .testTarget(name: "KoreLinkTests", dependencies: ["KoreLink", "LinkProtocol", "KoreUI", "src", "KoreCore"]),
        .testTarget(name: "KoreHostTests", dependencies: ["KoreHost", "LinkProtocol", "src", "KoreCore", "kore-host"]),
        .testTarget(name: "HostClientTests", dependencies: ["HostClient", "KoreHost", "LinkProtocol", "src", "KoreCore"]),
        .testTarget(name: "StorylineTests", dependencies: ["KoreStorylines", "KoreUI", "src", "KoreCore"]),
    ]
)
