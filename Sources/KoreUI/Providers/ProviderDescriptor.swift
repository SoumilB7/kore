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
