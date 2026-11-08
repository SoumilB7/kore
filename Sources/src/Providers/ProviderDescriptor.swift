import Foundation
import KoreCore

/// Everything Kore knows about one CLI. A new CLI is a folder under `Providers/` (its backend
/// and its descriptor) plus one line in `Registry`; nothing else switches on which CLI it is.
package struct ProviderDescriptor: Identifiable, Sendable {
    /// Stored in saved tabs.
    package let id: String
    package let name: String
    /// SVG, and whether it takes the surrounding foreground colour.
    package let logoSVG: String
    package let logoIsTemplate: Bool
    /// Permission modes as the CLI's VS Code extension shows them; the first is the default.
    package let modes: [ModeOption]
    /// A plan switch kept apart from the modes (Codex); nil where plan is a mode (Claude).
    package let planToggle: ModeOption?
    /// How `SessionSummary` (KoreCore) names this CLI.
    package let historyAgent: SessionSummary.Agent
    /// The modes to offer with this model.
    package let availableModes: @Sendable (_ model: ModelOption?) -> [ModeOption]
    /// Shift+Tab, as in the CLI.
    package let nextMode: @Sendable (_ mode: String, _ planMode: Bool, _ available: [ModeOption]) -> ModeStep
    package let makeBackend: @MainActor @Sendable (BackendOptions) -> any ChatBackend
    /// The folder's chats; nil when the CLI couldn't be asked.
    package let sessions: @Sendable (_ folder: URL) async -> [SessionSummary]?
    package let setArchived: @Sendable (_ id: String, _ archived: Bool, _ folder: URL) async -> Void
    /// A chat's own history file (what an import of it reads); nil when there's none.
    package let historyFile: @Sendable (_ id: String, _ folder: URL) async -> URL?
    /// What the usage popup says of this CLI without a reading.
    package let usage: UsageWording
    /// Its login: the sign-in methods, the status, the file it's kept in.
    package let account: AccountOps
    /// What New tab's install card says of its official installer.
    package var install = InstallWording(maker: "", source: "")
}

/// The install card's words for one CLI's official installer.
package struct InstallWording: Sendable {
    /// Whose installer it is ("Anthropic's official installer").
    package let maker: String
    /// Where it comes from and goes, in one line.
    package let source: String
}

/// The usage popup's words for one CLI.
package struct UsageWording: Sendable {
    /// What it's called, in Kore's lines about it ("the claude CLI").
    package let product: String
    /// The limits it usually has, drawn empty while the first reading loads.
    package let rows: [String]
    /// What a full reset does, in the CLI's own words, over the list of them; nil for a CLI
    /// without full resets.
    package let resetsCaption: String?
    /// What fast mode costs, from the CLI maker's published rates: the multiplier shown by the
    /// bolt ("2×") and the line on hovering it.
    package var fastCost = FastCost(times: "", detail: "")

    /// Kore's wording for a CLI that isn't signed in: where to sign in.
    package var signedOut: String { "\(product) isn't signed in. Sign in from Account in the / menu." }

    /// The reason line when the limits couldn't be read: the CLI's own words after it, if any.
    package func failed(_ detail: String?) -> String {
        "Couldn't read limits from \(product)" + (detail.map { ": " + $0 } ?? ".")
    }
}

package struct FastCost: Sendable {
    package let times: String
    package let detail: String
}

package enum ModeStep {
    case mode(String)
    case togglePlan
}

extension ProviderDescriptor: Hashable {
    package static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    package func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ProviderDescriptor {
    /// A saved tab's provider.
    package init?(rawValue: String) {
        guard let provider = Registry.provider(rawValue) else { return nil }
        self = provider
    }

    package var rawValue: String { id }

    package static var allCases: [ProviderDescriptor] { Registry.all }
}

/// The CLIs Kore can run, in picker order.
package enum Registry {
    package static let all: [ProviderDescriptor] = [.claude, .codex]

    package static func provider(_ id: String) -> ProviderDescriptor? { all.first { $0.id == id } }

    package static func provider(for agent: SessionSummary.Agent) -> ProviderDescriptor {
        all.first { $0.historyAgent == agent } ?? all[0]
    }
}
