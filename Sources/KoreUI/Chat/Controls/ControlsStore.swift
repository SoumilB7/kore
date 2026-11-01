import Observation
import SwiftUI

/// The chat's mode, model, effort and `/` commands: what the composer bar shows. Model and
/// effort changes are optimistic; `Chat` sends them to the backend.
@MainActor @Observable
package final class ControlsStore {
    let provider: ProviderDescriptor
    /// The provider's mode id (Claude permission mode / Codex permissions preset).
    package var mode: String
    /// The provider's plan toggle (Codex); Claude's plan is a mode.
    package var planMode = false
    /// "Allow commands in Plan": while planning, Kore answers each permission with allow.
    var planAllow = false
    private(set) var models: [ModelOption] = []
    var modelId: String?
    var effort: String?
    /// Fast mode: as the CLI last said, or as the user just set it.
    var fastMode = false
    /// On, at standard speed for now (after a rate limit).
    private(set) var fastPaused = false
    /// The account can have fast mode, as the CLI last said.
    private(set) var fastOffered: Bool?
    private(set) var fastKnown = false
    private(set) var fastUnavailable: String?
    var fastChanging = false
    /// The CLI's own remote control of the chat (`/` → Remote control); nil while it's off.
    private(set) var remote: RemoteControl?
    /// Why the CLI can't offer it at all; nil when it can, or can't say yet.
    private(set) var remoteUnavailable: String?
    var remoteChanging = false
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
            // A fresh CLI may belong to another login. Its capability report must not inherit
            // an account blocker (or permission) from the previous process.
            fastKnown = false
            fastOffered = nil
            fastUnavailable = nil
            (fastMode, fastPaused) = (false, false)
        case .modeChanged(let change):
            mode = change.mode
        case .planModeChanged(let change):
            planMode = change.on
        case .fastModeChanged(let report):
            // A model without it reports it off, and the switch is hidden on it: the CLI keeps the
            // setting for the next model that has it.
            fastKnown = true
            guard currentModel?.supportsFastMode != false else { return }
            (fastMode, fastPaused) = (report.on, report.on && report.paused)
            if let offered = report.offered {
                fastOffered = offered
                fastUnavailable = offered ? nil : report.unavailable ?? "Unavailable for this account"
            }
        case .remoteControl(let state):
            remote = state
        case .remoteControlUnavailable(let reason):
            remoteUnavailable = reason
        case .replayed(let events):
            events.forEach(apply)
        default:
            break
        }
    }

    package var availableModes: [ModeOption] { provider.availableModes(currentModel) }

    /// The mode is one this model offers (a model without Auto doesn't).
    var modeOffered: Bool { availableModes.contains { $0.id == mode } }

    var activeMode: ModeOption {
        if planMode, let plan = provider.planToggle { return plan }
        return permissionsMode
    }

    /// Planning: Claude's Plan mode, or Codex's Plan switch on.
    var planning: Bool { activeMode.id == "plan" }

    /// Kore answers it with allow itself, no card: a plain permission while planning with the switch on.
    func autoAllows(_ approval: Approval) -> Bool { planAllow && planning && approval.isPermission }

    /// The chat's own switch, kept under its session id.
    func restorePlanAllow(chat session: String) { planAllow = memory.planAllow(chat: session) }
    func keepPlanAllow(chat session: String) { memory.remember(planAllow: planAllow, chat: session) }

    /// The mode apart from a plan toggle.
    var permissionsMode: ModeOption { provider.modes.first { $0.id == mode } ?? provider.modes[0] }

    /// The chat's highlight colour for the active mode; nil when neutral.
    var tint: Color? { activeMode.tint }

    package var currentModel: ModelOption? { models.first { $0.id == modelId } }

    /// A supported model and a CLI that reports fast mode. Unknown account availability
    /// allows an explicit opt-in; an actual blocker stays visible with its reason.
    var fastModeShown: Bool { fastKnown && currentModel?.supportsFastMode == true }
    var fastModeEnabled: Bool { fastModeShown && (fastMode || fastOffered != false) && !fastChanging }

    var modelLabel: String { currentModel?.name ?? modelId ?? provider.name }

    /// Nil for a model without efforts: the pill shows the model alone.
    var effortLabel: String? {
        guard let effort, currentModel?.efforts.isEmpty != true else { return nil }
        return EffortScale.name(effort)
    }

    /// Every level the CLI's models offer, lowest first: the picker's slider.
    var effortScale: [String] { EffortScale.levels(models) }
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

    /// Each chat's "Allow commands in Plan", by its session id ("planAllow.chat.<id>"); only kept while on.
    private static let planAllowKey = "planAllow.chat."

    func planAllow(chat session: String) -> Bool { defaults?.bool(forKey: Self.planAllowKey + session) ?? false }

    func remember(planAllow on: Bool, chat session: String) {
        if on { defaults?.set(true, forKey: Self.planAllowKey + session) } else { defaults?.removeObject(forKey: Self.planAllowKey + session) }
    }
}

/// Each chat's auto-compact point, by its session id ("autoCompact.chat.<id>", one small entry
/// each): a percent, 0 for off. The chat opens at it again; other chats aren't touched. Kept and
/// read under the same rule as the mode.
struct AutoCompactMemory {
    private static let chatKey = "autoCompact.chat."
    /// Nil keeps and reads nothing.
    let defaults: UserDefaults?

    @MainActor static var shared: AutoCompactMemory { AutoCompactMemory(defaults: ModeMemory.shared.defaults) }

    /// The session's own point: nil when it has none, `.some(nil)` when it's Off.
    func point(chat session: String) -> Int?? {
        guard let value = defaults?.object(forKey: Self.chatKey + session) as? Int else { return nil }
        if value == 0 { return .some(nil) }
        return ContextStore.snapPoints.contains(value) ? .some(value) : nil
    }

    func remember(_ point: Int?, chat session: String) {
        let value: Any = point ?? 0
        defaults?.set(value, forKey: Self.chatKey + session)
    }
}
