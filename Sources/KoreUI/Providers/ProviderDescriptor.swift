import AppKit
import KoreCore

/// Everything Kore knows about one CLI. A new CLI is a folder under `Providers/` (its backend
/// and its descriptor) plus one line in `Registry`; nothing else switches on which CLI it is.
struct ProviderDescriptor: Identifiable, Sendable {
    /// Stored in saved tabs.
    let id: String
    let name: String
    /// SVG, and whether it takes the surrounding foreground colour.
    let logoSVG: String
    let logoIsTemplate: Bool
    /// Permission modes as the CLI's VS Code extension shows them; the first is the default.
    let modes: [ModeOption]
    /// A plan switch kept apart from the modes (Codex); nil where plan is a mode (Claude).
    let planToggle: ModeOption?
    /// How `SessionSummary` (KoreCore) names this CLI.
    let historyAgent: SessionSummary.Agent
    /// The modes to offer with this model.
    let availableModes: @Sendable (_ model: ModelOption?) -> [ModeOption]
    /// Shift+Tab, as in the CLI.
    let nextMode: @Sendable (_ mode: String, _ planMode: Bool, _ available: [ModeOption]) -> ModeStep
    let makeBackend: @MainActor @Sendable (BackendOptions) -> any ChatBackend
    /// The folder's chats; nil when the CLI couldn't be asked.
    let sessions: @Sendable (_ folder: URL) async -> [SessionSummary]?
    let setArchived: @Sendable (_ id: String, _ archived: Bool, _ folder: URL) async -> Void
    /// A chat's own history file (what an import of it reads); nil when there's none.
    let historyFile: @Sendable (_ id: String, _ folder: URL) async -> URL?
    /// What the usage popup says of this CLI without a reading.
    let usage: UsageWording
    /// Its login: the sign-in methods, the status, the file it's kept in.
    let account: AccountOps
}

/// The usage popup's words for one CLI.
struct UsageWording: Sendable {
    /// What it's called, in Kore's lines about it ("Claude Code").
    let product: String
    /// The limits it usually has, drawn empty while the first reading loads.
    let rows: [String]
    /// What a full reset does, in the CLI's own words, over the list of them; nil for a CLI
    /// without full resets.
    let resetsCaption: String?
    /// What fast mode costs, from the CLI maker's published rates: the multiplier shown by the
    /// bolt ("2×") and the line on hovering it.
    var fastCost = FastCost(times: "", detail: "")

    /// Kore's wording for a CLI that isn't signed in: where to sign in.
    var signedOut: String { "\(product) isn't signed in. Sign in from Account in the / menu." }

    /// The reason line when the limits couldn't be read: the CLI's own words after it, if any.
    func failed(_ detail: String?) -> String {
        "Couldn't read limits from \(product)" + (detail.map { ": " + $0 } ?? ".")
    }
}

struct FastCost: Sendable {
    let times: String
    let detail: String
}

enum ModeStep {
    case mode(String)
    case togglePlan
}

extension ProviderDescriptor: Hashable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ProviderDescriptor {
    @MainActor var logo: NSImage {
        if let image = Self.logos[id] { return image }
        let image = NSImage(data: Data(logoSVG.utf8)) ?? NSImage()
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = logoIsTemplate
        Self.logos[id] = image
        return image
    }

    @MainActor private static var logos: [String: NSImage] = [:]

    /// A saved tab's provider.
    init?(rawValue: String) {
        guard let provider = Registry.provider(rawValue) else { return nil }
        self = provider
    }

    var rawValue: String { id }

    static var allCases: [ProviderDescriptor] { Registry.all }
}

/// Kore's views still say `Provider`.
typealias Provider = ProviderDescriptor

/// The CLIs Kore can run, in picker order.
enum Registry {
    static let all: [ProviderDescriptor] = [.claude, .codex]

    static func provider(_ id: String) -> ProviderDescriptor? { all.first { $0.id == id } }

    static func provider(for agent: SessionSummary.Agent) -> ProviderDescriptor {
        all.first { $0.historyAgent == agent } ?? all[0]
    }
}
