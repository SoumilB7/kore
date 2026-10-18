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

    init(provider: ProviderDescriptor) {
        self.provider = provider
        mode = provider.modes[0].id
    }

    func apply(_ event: ChatEvent) {
        switch event {
        case .controlsLoaded(let controls):
            models = controls.models
            modelId = controls.model
            effort = controls.effort
            commands = controls.commands
        case .modeChanged(let id):
            mode = id
        case .planModeChanged(let on):
            planMode = on
        case .replayed(let events):
            events.forEach(apply)
        default:
            break
        }
    }

    var availableModes: [ModeOption] { provider.availableModes(currentModel) }

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
