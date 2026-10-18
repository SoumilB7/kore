import Observation
import SwiftUI

/// The chat's mode, model, effort and `/` commands: what the composer bar shows. Model and
/// effort changes are optimistic; `Chat` sends them to the backend.
@MainActor @Observable
final class ControlsStore {
    let provider: ProviderDescriptor
    /// The provider's mode id (Claude permission mode / Codex permissions preset).
    var mode: String
    /// The provider's plan toggle (Codex); Claude's plan is a mode.
    var planMode = false
    private(set) var models: [ModelOption] = []
    var modelId: String?
    var effort: String?
    private(set) var commands: [SlashCommand] = []
    /// Who changed the mode last, when it was the agent ("Claude", a sub-agent's name); nil
    /// once the user sets it. The pill's help says so.
    var changedBy: String?
    /// Bumped by each agent change: the pill flashes once.
    var agentChangeSeq = 0
    private let memory: ModeMemory

    /// Starts in the mode the user last picked, while it's offered; else the provider's first.
    init(provider: ProviderDescriptor, memory: ModeMemory = .shared) {
        self.provider = provider
        self.memory = memory
        let offered = provider.availableModes(nil)
        mode = memory.mode(for: provider).flatMap { id in offered.first { $0.id == id && $0.id != "plan" }?.id } ?? provider.modes[0].id
    }

    /// The user picked `id`: new chats start in it. Plan isn't kept: it's for the task at hand.
    func remember(_ id: String) {
        guard id != "plan", provider.modes.contains(where: { $0.id == id }) else { return }
        memory.remember(id, for: provider)
    }

    func apply(_ event: ChatEvent) {
        switch event {
        case .controlsLoaded(let controls):
            models = controls.models
            modelId = controls.model
            effort = controls.effort
            commands = controls.commands
        case .modeChanged(let change):
            mode = change.mode
        case .planModeChanged(let change):
            planMode = change.on
        case .replayed(let events):
            events.forEach(apply)
        default:
            break
        }
    }

    var availableModes: [ModeOption] { provider.availableModes(currentModel) }

    /// The mode is one this model offers (a model without Auto doesn't).
    var modeOffered: Bool { availableModes.contains { $0.id == mode } }

    var activeMode: ModeOption {
        if planMode, let plan = provider.planToggle { return plan }
        return permissionsMode
    }

    /// The mode apart from a plan toggle.
    var permissionsMode: ModeOption { provider.modes.first { $0.id == mode } ?? provider.modes[0] }

    /// The chat's highlight colour for the active mode; nil when neutral.
    var tint: Color? { activeMode.tint }

    var currentModel: ModelOption? { models.first { $0.id == modelId } }

    var modelLabel: String { currentModel?.name ?? modelId ?? provider.name }

    var effortLabel: String? {
        guard let effort else { return nil }
        return effort == "xhigh" ? "Extra high" : effort.capitalized
    }
}

/// The mode the user last picked for each provider, which new chats start in: one small key
/// per provider ("lastMode.claude"). The agent's own changes aren't picks.
struct ModeMemory {
    private static let key = "lastMode."
    /// Nil keeps and reads nothing.
    let defaults: UserDefaults?

    /// Dev runs (any KORE_ hook) and storylines start where a fresh install does, and leave
    /// the owner's choice alone.
    @MainActor static var shared: ModeMemory {
        let dev = StoryHost.installed || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("KORE_") }
        return ModeMemory(defaults: dev ? nil : .standard)
    }

    func mode(for provider: ProviderDescriptor) -> String? { defaults?.string(forKey: Self.key + provider.id) }

    func remember(_ id: String, for provider: ProviderDescriptor) { defaults?.set(id, forKey: Self.key + provider.id) }
}
