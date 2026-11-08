import Foundation
import src

/// What Own lets a chat's agent change on its own chat, through `kore` (`z-docs/agent-protocol.md`):
/// its name, model, effort and fast mode, its mode only downwards, and a compaction. Each takes only
/// what the chat's controls offer now, as the composer's pickers do, and says what it did in the
/// transcript, so the change is seen where it happened. Nothing here raises a mode.
package struct ArsenalRefusal: Error, Sendable {
    package let message: String
    init(_ message: String) { self.message = message }
}

/// The choices Own has on a chat now.
package struct ArsenalOptions: Sendable {
    package struct Model: Sendable {
        package let id: String
        package let name: String
        package let efforts: [String]
    }

    package struct Mode: Sendable {
        package let id: String
        package let label: String
        /// At or below the chat's mode now: Own may pick it.
        package let allowed: Bool
    }

    package let models: [Model]
    package let model: String?
    package let effort: String?
    package let modes: [Mode]
    package let mode: String
    /// nil while this chat's model has no fast mode.
    package let fast: Bool?
}

extension Chat {
    /// How far a mode lets the CLI go without asking, lowest first: planning; asking for each
    /// command (Claude's Manual, and Don't ask, which refuses what Manual would ask); editing; Codex's
    /// Read only, which reads any file on the Mac without asking (Claude's modes below it ask for a
    /// read outside the folder), the start Arsenal gives a Codex chat it opens; Codex's Ask for
    /// approval, which runs commands in the workspace without asking; approving by itself;
    /// everything. Codex's modes sit on rungs of their own, so none is a step down to a freer one.
    static func modeLevel(_ id: String) -> Int {
        switch id {
        case "plan": 0
        case "default", "dontAsk": 1
        case "acceptEdits": 2
        case "readOnly": 3
        case "askForApproval": 4
        case "auto", "approveForMe": 5
        default: top
        }
    }

    /// Bypass permissions, Full access, and any mode Kore doesn't know.
    static let top = 6

    /// The mode that says what the CLI may do on its own. Codex's Plan switch changes how it works
    /// but restricts nothing (its sandbox and approvals stay the permissions'), so a Codex chat
    /// ranks by its permissions; Claude's Plan is a mode of its own. `unreviewed`: planning with
    /// "Allow commands in Plan" on, where Kore allows each permission itself.
    var arsenalRank: (id: String, unreviewed: Bool) {
        let id = provider.planToggle == nil ? controls.activeMode.id : controls.permissionsMode.id
        return (id, controls.planning && controls.planAllow)
    }

    /// Whether Arsenal may move this chat to `id`: a mode at or below the one it's in, unless the
    /// move would let the CLI do without the user what it couldn't before. Plan with "Allow commands
    /// in Plan" on approves commands itself; Edit automatically from Auto drops Auto's review of
    /// edits. Those stay the user's. A Codex chat compares its permissions (`arsenalRank`).
    func arsenalMayMove(to id: String) -> Bool {
        if id == "plan" { return !controls.planAllow || controls.planning }
        let now = arsenalRank.id
        guard Self.modeLevel(id) <= Self.modeLevel(now) else { return false }
        if id == "acceptEdits", now == "auto" { return false }
        return true
    }

    /// A chat at `id` can do on its own no more than one at `other` can: lower on the ladder, with
    /// an unreviewed Plan above all but the top (and under only Plan or another unreviewed one no
    /// higher), and Edit automatically not under Auto (it accepts edits Auto would review). Ids as
    /// `arsenalRank` gives them.
    package static func noFreer(_ id: String, unreviewed: Bool, than other: String, unreviewed otherUnreviewed: Bool) -> Bool {
        if modeLevel(other) >= top { return true }
        if otherUnreviewed { return modeLevel(id) == 0 && !unreviewed || unreviewed && modeLevel(id) <= modeLevel(other) }
        if unreviewed { return false }
        if id == "acceptEdits", other == "auto" { return false }
        return modeLevel(id) <= modeLevel(other)
    }

    package var arsenalOptions: ArsenalOptions {
        var modes = controls.availableModes.filter(\.listed)
        if let plan = provider.planToggle, !modes.contains(where: { $0.id == plan.id }) { modes.insert(plan, at: 0) }
        return ArsenalOptions(
            models: controls.models.map { .init(id: $0.id, name: $0.name, efforts: $0.efforts) },
            model: controls.currentModel?.id ?? controls.modelId,
            effort: controls.effort,
            modes: modes.map { .init(id: $0.id, label: $0.label, allowed: arsenalMayMove(to: $0.id)) },
            mode: controls.activeMode.id,
            fast: controls.fastModeShown ? controls.fastMode : nil)
    }

    /// Without controls, format characters (bidi overrides and isolates, zero-width marks) or line
    /// and paragraph separators, and not a name another open chat has (`taken`): chats are named by
    /// their titles to `kore`, so one can't take another's.
    package func arsenalRename(_ title: String, taken: [String]) -> Result<String, ArsenalRefusal> {
        let dropped: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter { !dropped.contains($0.properties.generalCategory) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .failure(.init("A name needs some text.")) }
        guard clean.count <= 100 else { return .failure(.init("A name can be 100 characters at most.")) }
        guard !taken.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else {
            return .failure(.init("Another open chat is named that."))
        }
        rename(clean)
        return .success("Renamed.")
    }

    /// `name`: a model's id or name, as the picker lists it.
    package func arsenalModel(_ name: String) -> Result<String, ArsenalRefusal> {
        // The chat's own list (a Codex chat's, Codex's), else its CLI's as last listed in this run.
        let models = controls.models.isEmpty ? ArsenalModels.seen[provider.id] ?? [] : controls.models
        guard !models.isEmpty else { return .failure(.init("Kore doesn't have this CLI's models yet. Try again after its first turn.")) }
        let option: ModelOption
        switch ArsenalModels.find(name, in: models, cli: "This chat") {
        case .success(let found): option = found
        case .failure(let refusal): return .failure(refusal)
        }
        guard option.id != controls.modelId else { return .success("Already \(option.name).") }
        setModel(option)
        note("Arsenal · model \(option.name)")
        return .success("Model \(option.name).")
    }

    package func arsenalEffort(_ level: String) -> Result<String, ArsenalRefusal> {
        let offered = controls.currentModel?.efforts ?? []
        guard let match = offered.first(where: { $0.lowercased() == level.lowercased() }) else {
            return .failure(.init(offered.isEmpty ? "This chat's model has no effort setting." : "This model offers: " + offered.joined(separator: ", ")))
        }
        guard match != controls.effort else { return .success("Already \(match).") }
        setEffort(match)
        note("Arsenal · effort \(match)")
        return .success("Effort \(match).")
    }

    package func arsenalFast(_ on: Bool) -> Result<String, ArsenalRefusal> {
        guard controls.fastModeEnabled else { return .failure(.init(controls.fastUnavailable ?? "This chat's model has no fast mode.")) }
        guard on != controls.fastMode else { return .success(on ? "Already fast." : "Already standard speed.") }
        setFastMode(on)
        note(on ? "Arsenal · fast mode on" : "Arsenal · fast mode off")
        return .success(on ? "Fast mode on." : "Fast mode off.")
    }

    /// Only to a mode at or below the one it's in: raising one stays the user's.
    package func arsenalMode(_ id: String) -> Result<String, ArsenalRefusal> {
        let options = arsenalOptions
        guard let mode = options.modes.first(where: { $0.id.lowercased() == id.lowercased() || $0.label.lowercased() == id.lowercased() }) else {
            return .failure(.init("This chat's modes: " + options.modes.map(\.id).joined(separator: ", ")))
        }
        guard mode.id != options.mode else { return .success("Already \(mode.label).") }
        guard mode.allowed else {
            if Self.modeLevel(mode.id) > Self.modeLevel(options.mode) {
                return .failure(.init("Only you can raise a chat's mode. \(mode.label) is above \(controls.activeMode.label)."))
            }
            return .failure(.init(mode.id == "plan"
                ? "“Allow commands in Plan” is on here, so Plan would approve commands by itself: only you can switch to it."
                : "Edit automatically accepts edits Auto would review: only you can switch to it."))
        }
        // After the answer has gone: leaving Codex's Full access ends this chat's access, and with
        // it the connection the answer goes on. Not remembered as the CLI's default.
        let plan = provider.planToggle?.id == mode.id
        Task { @MainActor [self] in
            // A Codex chat's plan is a switch over its permissions.
            if plan { setPlanMode(true) } else { setMode(mode.id, remember: false) }
            note("Arsenal · mode \(mode.label)")
        }
        let ends = provider == .codex && !plan && mode.id != CodexModes.fullAccess && arsenal != nil
        return .success(ends ? "Mode \(mode.label). Kore access ends with it: Codex's sandbox blocks it there." : "Mode \(mode.label).")
    }

    /// Now when the chat is idle, or once the turn running now ends (the agent asking is in it).
    package func arsenalCompact() -> Result<String, ArsenalRefusal> {
        if canCompact {
            compact()
            return .success("Compacting.")
        }
        guard status.sessionId != nil, !context.compacting else { return .failure(.init("Nothing to compact now.")) }
        compactAfterTurn = true
        return .success("Compacts when this turn ends.")
    }
}
