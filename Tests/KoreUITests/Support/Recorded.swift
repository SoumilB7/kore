import Foundation

@testable import KoreUI

/// The recorded runs as `ChatEvent` streams, each through its own CLI's translator.
@MainActor
enum Recorded {
    nonisolated static let claude = ["claude-tool", "claude-stop", "claude-plan", "claude-compact", "claude-queued-inturn", "claude-queued-nextturn"]
    nonisolated static let codex = ["codex-tool", "codex-steer", "codex-stop"]

    static func events(_ name: String) throws -> [ChatEvent] {
        name.hasPrefix("codex") ? try Drive.codex(name) : try Drive.claude(name)
    }

    /// Every run one after another, as one long chat (their ids don't overlap).
    static func all() throws -> [ChatEvent] {
        try (claude + codex).flatMap(events)
    }
}

/// A small seeded generator (SplitMix64), so a failing random run can be run again.
struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
