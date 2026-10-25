import AppKit
import Observation
import SwiftUI

/// The model and mode pickers' state in one chat: which is open (one at a time, in the popups'
/// place), where the keys and the pointer are, and the rows whose folded chips were shown.
@MainActor @Observable
final class PickerState {
    enum Kind: Equatable {
        case model, mode

        /// Its kind among what's open over the composer.
        var popup: OpenPopup { self == .model ? .model : .mode }
    }

    private(set) var open: Kind?
    /// What the hover fill is on: the chip or row under the pointer, or where the arrows put it.
    var lit: PickerSpot?
    /// Families whose "…" chip was pressed: their row wraps to show every version.
    private(set) var unfolded: Set<String> = []
    /// The chip and pill (global frames): a click on one isn't outside its popup, so the chip's
    /// own action can close it. Kept for the click monitor, never shown.
    @ObservationIgnored var chips: [Kind: CGRect] = [:]

    func toggle(_ kind: Kind) {
        if open == kind { return close() }
        (open, lit, unfolded) = (kind, nil, [])
    }

    func close() {
        guard open != nil else { return }
        (open, lit, unfolded) = (nil, nil, [])
    }

    func unfold(_ family: String) { unfolded.insert(family) }

    /// The pointer left `spot`: its fill goes, unless the keys have moved it on.
    func leave(_ spot: PickerSpot) {
        if lit == spot { lit = nil }
    }
}

/// The model chip's popup (model-picker.html, A): one row per family, its versions newest first
/// as chips, the current model the one accent chip; a rule, then effort as a slider, and fast
/// mode's switch where the account and the model can have it. A pick applies at once and the
/// popup stays, so effort can follow; Return picks and closes, Space picks and stays, Esc, a
/// click outside or typing closes it. Chips that don't fit fold into a "…" chip, which wraps the
/// row when pressed.
struct ModelPicker: View {
    let chat: Chat
    let state: PickerState
    /// The chips' column, measured: how many chips a row has room for.
    @StateObject private var room = Local<CGFloat>(.infinity)

    private var controls: ControlsStore { chat.controls }

    var body: some View {
        let families = ModelFamily.group(controls.models)
        ComposerPopup(
            chat: chat, id: StoryID.Composer.models, isOpen: { state.open == .model }, stepBack: { false },
            close: { state.close() }, keys: { key($0, families) }, spare: { state.chips[.model] }
        ) {
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 0) {
                ForEach(Array(families.enumerated()), id: \.element.name) { row, family in
                    GridRow {
                        name(family, row: row)
                        chips(family, row: row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room.value = $0 }
                    }
                    .frame(minHeight: Size.Picker.row)
                }
                let scale = controls.effortScale
                if !scale.isEmpty || controls.fastModeShown {
                    Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                        .gridCellColumns(2)
                        .padding(.vertical, Space.sm)
                }
                if !scale.isEmpty || controls.fastModeShown {
                    GridRow(alignment: .top) {
                        let offered = controls.currentModel?.efforts ?? []
                        Text(scale.isEmpty ? "Speed" : "Effort")
                            .font(TextStyle.bodyMedium)
                            .foregroundStyle(offered.isEmpty && !scale.isEmpty ? Theme.tertiary : Theme.text)
                            .frame(minHeight: Size.hitTarget)
                        // Fast mode beside the effort, a gap apart: one bolt, filled while it's on.
                        HStack(alignment: .top, spacing: Space.xl) {
                            if !scale.isEmpty {
                                EffortSlider(
                                    scale: scale, offered: offered, current: controls.effort, lit: state.lit == .effort,
                                    set: { chat.setEffort($0) })
                            } else {
                                Spacer(minLength: 0)
                            }
                            if controls.fastModeShown {
                                FastBolt(
                                    on: controls.fastMode, paused: controls.fastPaused, unavailable: controls.fastUnavailable,
                                    enabled: controls.fastModeEnabled, lit: state.lit == .fast, cost: chat.provider.usage.fastCost) {
                                    flipFast()
                                } hover: {
                                    hover(.fast, $0)
                                }
                                .storyID(StoryID.Composer.fastMode)
                                .tabStop(StoryID.Composer.fastMode) { flipFast() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func flipFast() { chat.setFastMode(!controls.fastMode) }

    // MARK: Rows

    /// The family's name, which picks its newest version; hovering it lights that chip. A
    /// family of one with no number is its own chip.
    @ViewBuilder private func name(_ family: ModelFamily, row: Int) -> some View {
        let spot = PickerSpot.chip(row: row, column: 0)
        if family.versionless {
            VersionChip(
                label: family.name, current: family.newest.id == controls.modelId, lit: state.lit == spot, name: true,
                pick: { pick(family.newest) }, hover: { hover(spot, $0) }
            )
            .storyID(StoryID.Composer.modelChip(family.newest.id))
            .tabStop(StoryID.Composer.modelChip(family.newest.id)) { pick(family.newest) }
            // Its name in line with the other families', its fill reaching past it.
            .padding(.leading, -Space.md)
        } else {
            Button {
                pick(family.newest)
            } label: {
                Text(family.name)
                    .font(TextStyle.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: Size.Picker.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover(spot, $0) }
            .storyID(StoryID.Composer.modelFamily(family.name))
        }
    }

    /// The versions, newest first: as many as fit, then a "…" chip; all of them, wrapped, once
    /// it's pressed (or the keys or the current model are past the fold).
    @ViewBuilder private func chips(_ family: ModelFamily, row: Int) -> some View {
        if family.versionless {
            Color.clear.frame(height: Size.Picker.chip)
        } else {
            let labels = family.members.map { $0.version ?? $0.model.name }
            let shown = ModelFamily.fold(
                labels.map(ModelFamily.chipWidth), more: ModelFamily.chipWidth("…"), gap: Space.xs, room: room.value)
            let current = family.members.firstIndex { $0.model.id == controls.modelId }
            let keyed: Int? = if case .chip(row, let column) = state.lit { column } else { nil }
            let past = [current, keyed].compactMap { $0 }.contains { $0 >= shown }
            if shown >= labels.count || past || state.unfolded.contains(family.name) {
                ChipFlow(spacing: Space.xs) {
                    ForEach(Array(family.members.enumerated()), id: \.element.model.id) { column, member in
                        chip(member, labels[column], row: row, column: column)
                    }
                }
            } else {
                HStack(spacing: Space.xs) {
                    ForEach(Array(family.members.prefix(shown).enumerated()), id: \.element.model.id) { column, member in
                        chip(member, labels[column], row: row, column: column)
                    }
                    MoreChip { state.unfold(family.name) }
                        .storyID(StoryID.Composer.modelFold(family.name))
                        .tabStop(StoryID.Composer.modelFold(family.name)) { state.unfold(family.name) }
                }
            }
        }
    }

    private func chip(_ member: ModelFamily.Member, _ label: String, row: Int, column: Int) -> some View {
        let spot = PickerSpot.chip(row: row, column: column)
        return VersionChip(
            label: label, current: member.model.id == controls.modelId, lit: state.lit == spot,
            pick: { pick(member.model) }, hover: { hover(spot, $0) }
        )
        .storyID(StoryID.Composer.modelChip(member.model.id))
        .tabStop(StoryID.Composer.modelChip(member.model.id)) { pick(member.model) }
        .help(member.model.name)
    }

    // MARK: Picking

    private func pick(_ model: ModelOption) {
        if model.id != controls.modelId { chat.setModel(model) }
    }

    /// The pointer moves the one highlight, as in a menu; a chip the keys' highlight sits under
    /// a resting pointer keeps it until the pointer moves.
    private func hover(_ spot: PickerSpot, _ inside: Bool) {
        guard PointerGate.moved else { return }
        if inside { state.lit = spot } else { state.leave(spot) }
    }

    /// Where the current model's chip is, for the first arrow.
    private func currentSpot(_ families: [ModelFamily]) -> PickerSpot {
        for (row, family) in families.enumerated() {
            if let column = family.members.firstIndex(where: { $0.model.id == controls.modelId }) {
                return .chip(row: row, column: column)
            }
        }
        return .chip(row: 0, column: 0)
    }

    private func model(at spot: PickerSpot?, _ families: [ModelFamily]) -> ModelOption? {
        guard case .chip(let row, let column) = spot, families.indices.contains(row),
            families[row].members.indices.contains(column)
        else { return nil }
        return families[row].members[column].model
    }

    /// ←→ versions (or, on the slider, the level, live), ↑↓ families and down to the slider and
    /// the switch; Return picks (or flips) and closes, Space picks and stays. Any other key isn't
    /// the picker's.
    private func key(_ event: NSEvent, _ families: [ModelFamily]) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let grid = ModelPickerGrid(
            rows: families.map(\.members.count), effort: !controls.effortScale.isEmpty, fast: controls.fastModeShown)
        let move: ModelPickerGrid.Move? =
            switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            default: nil
            }
        if let move {
            PointerGate.keyed()
            let from = state.lit ?? currentSpot(families)
            if from == .effort, move == .left || move == .right {
                let offered = controls.currentModel?.efforts ?? []
                if let level = EffortScale.step(controls.effort, by: move == .left ? -1 : 1, offered: offered, scale: controls.effortScale),
                    level != controls.effort
                {
                    chat.setEffort(level)
                }
                state.lit = .effort
                return true
            }
            state.lit = grid.move(from, move)
            return true
        }
        // Nothing lit: Return and Space are the Tab ring's, or close it.
        guard state.lit != nil else { return false }
        switch event.keyCode {
        case 36, 76:
            if let model = model(at: state.lit, families) { pick(model) }
            if state.lit == .fast { flipFast() }
            state.close()
            return true
        case 49:
            if let model = model(at: state.lit, families) { pick(model) }
            if state.lit == .fast { flipFast() }
            return true
        default:
            return false
        }
    }
}

// MARK: - Pieces

/// A version chip: secondary at rest, the hover fill under the pointer or the keys, the current
/// model in the accent on the command fill.
private struct VersionChip: View {
    let label: String
    let current: Bool
    let lit: Bool
    /// A family's name standing as its one chip: the name's type.
    var name = false
    let pick: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: pick) {
            Text(label)
                .font(name ? TextStyle.bodyMedium : current ? TextStyle.labelMedium : TextStyle.label)
                .monospacedDigit()
                .foregroundStyle(current ? Theme.accent : lit || name ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Space.md)
                .frame(height: Size.Picker.chip)
                .background(fill, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var fill: Color {
        if current { return lit ? Theme.accentFillHover : Theme.commandFill }
        return lit ? Theme.Row.selected(.surface) : .clear
    }
}

/// Fast mode: a bolt, hollow while off and filled in the accent while on; the hover says what
/// it costs, or that a rate limit has it at standard speed for now.
private struct FastBolt: View {
    let on: Bool
    let paused: Bool
    let unavailable: String?
    let enabled: Bool
    let lit: Bool
    let cost: FastCost
    let flip: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: flip) {
            // The bolt and what it costs beside it, "2×": seen before it's turned on.
            HStack(spacing: Space.xxs) {
                Image(systemName: on ? "bolt.fill" : "bolt")
                    .font(TextStyle.title)
                    .foregroundStyle(on ? Theme.accent : lit ? Theme.text : Theme.secondary)
                if !cost.times.isEmpty {
                    Text(cost.times)
                        .font(TextStyle.caption).monospacedDigit()
                        .foregroundStyle(on ? Theme.accent : Theme.tertiary)
                }
            }
            .frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover(perform: hover)
        .help(unavailable ?? (paused ? "Standard speed for now, after a rate limit" : cost.detail.isEmpty ? "Fast mode: uses extra usage" : cost.detail))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fast mode"))
        .accessibilityValue(Text(unavailable ?? ((on ? "On" : "Off") + (cost.times.isEmpty ? "" : ", \(cost.times) usage"))))
        .accessibilityAddTraits(.isButton)
    }
}

/// The "…" chip of a row whose versions don't all fit: pressed, the row wraps to show them.
private struct MoreChip: View {
    let unfold: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: unfold) {
            Text("…")
                .font(TextStyle.label)
                .foregroundStyle(hovered.value ? Theme.text : Theme.tertiary)
                .padding(.horizontal, Space.md)
                .frame(height: Size.Picker.chip)
                .hoverFill(hovered.value, Theme.Row.selected(.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("More versions")
    }
}

/// Effort as a slider over every level the CLI's models offer, so it keeps its length: levels
/// this model lacks are hollow stops with tertiary labels, and the thumb skips them. A model
/// with none dims the track and has no thumb. Narrower than `labelsMin`, only the current
/// level is named.
private struct EffortSlider: View {
    let scale: [String]
    let offered: [String]
    let current: String?
    let lit: Bool
    let set: @MainActor @Sendable (String) -> Void
    @StateObject private var width = Local<CGFloat>(0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thumb: Int? { current.flatMap { offered.contains($0) ? scale.firstIndex(of: $0) : nil } }

    var body: some View {
        let narrow = width.value > 0 && width.value < Size.Picker.labelsMin
        VStack(spacing: 0) {
            GeometryReader { geometry in
                track(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(height: Size.hitTarget)
            .opacity(offered.isEmpty ? Theme.off : 1)
            HStack(spacing: 0) {
                ForEach(Array(scale.enumerated()), id: \.element) { index, level in
                    label(level, index: index, narrow: narrow)
                }
            }
        }
        .padding(.bottom, Space.xs)
        .hoverFill(lit, Theme.Row.selected(.surface))
        // A click on a level's column (its stop or its label) picks it, or the offered level
        // nearest it; a drag slides through the offered ones.
        .overlay {
            HStack(spacing: 0) {
                ForEach(Array(scale.enumerated()), id: \.element) { index, level in
                    Button {
                        pick(index)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .storyID(StoryID.Composer.effortLevel(level), press: press(level))
                }
            }
            .disabled(offered.isEmpty)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: Space.xs).onChanged { slide(to: $0.location.x) },
            including: offered.isEmpty ? .none : .all
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.value = $0 }
        .storyID(StoryID.Composer.effort)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort"))
        .accessibilityValue(Text(current.map(EffortScale.name) ?? "None"))
        .accessibilityAdjustableAction { direction in
            let step = EffortScale.step(current, by: direction == .increment ? 1 : -1, offered: offered, scale: scale)
            if let step { set(step) }
        }
    }

    /// Each level's column centre: the stops sit under their labels.
    private func x(_ index: Int, _ width: CGFloat) -> CGFloat {
        width / CGFloat(max(scale.count, 1)) * (CGFloat(index) + 0.5)
    }

    @ViewBuilder private func track(width: CGFloat, height: CGFloat) -> some View {
        let mid = height / 2
        let (start, end) = (x(0, width), x(scale.count - 1, width))
        Rectangle().fill(Theme.surfaceRaised)
            .frame(width: max(end - start, 0), height: Size.Picker.track)
            .position(x: (start + end) / 2, y: mid)
        if let thumb {
            let to = x(thumb, width)
            Rectangle().fill(Theme.accent)
                .frame(width: max(to - start, 0), height: Size.Picker.track)
                .position(x: (start + to) / 2, y: mid)
        }
        ForEach(Array(scale.enumerated()), id: \.element) { index, level in
            stop(offered: offered.contains(level), filled: thumb.map { index <= $0 } ?? false)
                .position(x: x(index, width), y: mid)
        }
        if let thumb {
            Circle().fill(Theme.text)
                .frame(width: Size.Picker.thumb, height: Size.Picker.thumb)
                .background(Circle().fill(Theme.surface).padding(-Size.Picker.thumbRing))
                .position(x: x(thumb, width), y: mid)
                .animation(reduceMotion ? nil : Motion.fade, value: thumb)
        }
    }

    @ViewBuilder private func stop(offered: Bool, filled: Bool) -> some View {
        if offered {
            Circle().fill(filled ? Theme.accent : Theme.surfaceRaised)
                .frame(width: Size.Picker.stop, height: Size.Picker.stop)
        } else {
            Circle().fill(Theme.surface)
                .overlay(Circle().strokeBorder(Theme.tertiary, lineWidth: Stroke.hairline))
                .frame(width: Size.Picker.stop, height: Size.Picker.stop)
        }
    }

    private func label(_ level: String, index: Int, narrow: Bool) -> some View {
        let isCurrent = index == thumb
        let has = offered.contains(level)
        // Over its column, not sizing it: the columns stay equal, under their stops.
        return Text(" ")
            .font(TextStyle.caption)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay {
                Text(EffortScale.name(level))
                    .font(TextStyle.caption)
                    .fontWeight(isCurrent ? .medium : .regular)
                    .foregroundStyle(isCurrent ? Theme.text : has ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(narrow && !isCurrent ? 0 : 1)
            }
    }

    /// A storyline's press on an offered level sets it; one the model lacks is clicked instead.
    private func press(_ level: String) -> (@MainActor @Sendable () -> Void)? {
        guard offered.contains(level) else { return nil }
        let set = set
        return { set(level) }
    }

    /// A drag at `x`: the offered level nearest the column it's over.
    private func slide(to x: CGFloat) {
        guard width.value > 0, !scale.isEmpty else { return }
        pick(Int(x / (width.value / CGFloat(scale.count))))
    }

    /// The offered level nearest the `stop`th.
    private func pick(_ stop: Int) {
        let stop = min(max(stop, 0), scale.count - 1)
        if let level = EffortScale.nearest(stop, offered: offered, scale: scale), level != current { set(level) }
    }
}

/// Chips in rows as wide as the room, wrapping: an unfolded family's versions.
private struct ChipFlow: SwiftUI.Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: placed.width, height: placed.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(bounds.width, subviews)
        for (subview, point) in zip(subviews, placed.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ room: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var (x, y, line, widest) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > room {
                (x, y, line) = (0, y + line + spacing, 0)
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + line)
    }
}
