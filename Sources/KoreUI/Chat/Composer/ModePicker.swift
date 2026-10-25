import AppKit
import SwiftUI

/// The mode pill's popup (model-picker.html, "The mode pill"): over the composer's trailing
/// edge, as wide as its rows. One 28pt row per mode the model offers, its icon in its rung's
/// tint, the current one with an accent ✓; Codex's Plan is a switch under a rule, and "Allow
/// commands in Plan" one after it. A click picks and closes (the switches stay); ↑↓ move, Return
/// picks and closes. ⇧Tab still cycles without it.
struct ModePicker: View {
    let chat: Chat
    let state: PickerState

    private var modes: [ModeOption] { chat.controls.availableModes }

    var body: some View {
        ComposerPopup(
            chat: chat, id: StoryID.Composer.modes, edge: .trailing, hugs: true, isOpen: { state.open == .mode },
            stepBack: { false }, close: { state.close() }, keys: key, spare: { state.chips[.mode] },
            corners: Theme.modeCorners(chat.controls.activeMode.rung)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    ModeRow(mode: mode, current: mode.id == chat.controls.mode, lit: state.lit == .row(index)) {
                        pick(index)
                    } hover: {
                        hover(.row(index), $0)
                    }
                    .storyID(StoryID.Composer.modeRow(mode.id))
                    .tabStop(StoryID.Composer.modeRow(mode.id)) { pick(index) }
                }
                if let plan = chat.provider.planToggle {
                    Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
                    PlanRow(mode: plan, on: chat.controls.planMode, lit: state.lit == .row(modes.count)) {
                        chat.setPlanMode(!chat.controls.planMode)
                    } hover: {
                        hover(.row(modes.count), $0)
                    }
                    .storyID(StoryID.Composer.modeRow(plan.id))
                    .tabStop(StoryID.Composer.modeRow(plan.id)) { chat.setPlanMode(!chat.controls.planMode) }
                } else {
                    Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
                }
                PlanAllowRow(on: chat.controls.planAllow, lit: state.lit == .row(allowIndex)) {
                    flipAllow()
                } hover: {
                    hover(.row(allowIndex), $0)
                }
                .storyID(StoryID.Composer.planAllow)
                .tabStop(StoryID.Composer.planAllow) { flipAllow() }
            }
        }
    }

    /// The "Allow commands in Plan" row: after the modes and Codex's Plan switch.
    private var allowIndex: Int { modes.count + (chat.provider.planToggle == nil ? 0 : 1) }
    private var count: Int { allowIndex + 1 }

    private func flipAllow() { chat.setPlanAllow(!chat.controls.planAllow) }

    /// The pointer moves the one highlight, unless it rests where the keys moved it from.
    private func hover(_ spot: PickerSpot, _ inside: Bool) {
        guard PointerGate.moved else { return }
        if inside { state.lit = spot } else { state.leave(spot) }
    }

    /// A mode row picks it and closes; the plan rows flip their switches.
    private func pick(_ index: Int) {
        if modes.indices.contains(index) {
            if modes[index].id != chat.controls.mode { chat.setMode(modes[index].id) }
            state.close()
        } else if index == modes.count, chat.provider.planToggle != nil {
            chat.setPlanMode(!chat.controls.planMode)
        } else if index == allowIndex {
            flipAllow()
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]), count > 0 else { return false }
        let at: Int = if case .row(let row) = state.lit { row } else { modes.firstIndex { $0.id == chat.controls.mode } ?? 0 }
        switch event.keyCode {
        case 125, 126:
            // From the current mode, as the model picker's arrows start from the current model.
            PointerGate.keyed()
            state.lit = .row(min(max(at + (event.keyCode == 125 ? 1 : -1), 0), count - 1))
            return true
        case 36, 76:
            // Nothing lit: Return is the Tab ring's, or closes it.
            guard case .row(let row) = state.lit else { return false }
            pick(row)
            state.close()
            return true
        default:
            return false
        }
    }
}

/// A mode: its icon in its tint, the label, the accent ✓ on the current one.
private struct ModeRow: View {
    let mode: ModeOption
    let current: Bool
    let lit: Bool
    let pick: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Space.md) {
                ModeIcon(mode: mode).foregroundStyle(mode.tint ?? Theme.secondary)
                Text(mode.label)
                    .font(current ? TextStyle.bodyMedium : TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Space.xl)
                Image(systemName: "checkmark")
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.accent)
                    .opacity(current ? 1 : 0)
            }
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.row, alignment: .leading)
            .hoverFill(lit, Theme.Row.selected(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// Codex's Plan, apart from the presets: a switch.
private struct PlanRow: View {
    let mode: ModeOption
    let on: Bool
    let lit: Bool
    let flip: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: flip) {
            HStack(spacing: Space.md) {
                ModeIcon(mode: mode).foregroundStyle(mode.tint ?? Theme.secondary)
                Text(mode.label)
                    .font(on ? TextStyle.bodyMedium : TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Space.xl)
                Toggle("", isOn: Binding(get: { on }, set: { if $0 != on { flip() } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.row, alignment: .leading)
            .hoverFill(lit, Theme.Row.selected(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(mode.label))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(.isButton)
    }
}

/// "Allow commands in Plan": while planning, Kore answers every permission with allow.
private struct PlanAllowRow: View {
    let on: Bool
    let lit: Bool
    let flip: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: flip) {
            HStack(spacing: Space.md) {
                Text("Allow commands in Plan")
                    .font(on ? TextStyle.bodyMedium : TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Space.xl)
                Toggle("", isOn: Binding(get: { on }, set: { if $0 != on { flip() } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.row, alignment: .leading)
            .hoverFill(lit, Theme.Row.selected(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .help("Runs every command without asking while planning")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Allow commands in Plan"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(.isButton)
    }
}
