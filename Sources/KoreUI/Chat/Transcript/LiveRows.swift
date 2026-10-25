import SwiftUI

/// The running turn's last row, as in the Claude Code extension (look.md §12): a glyph cycling
/// `· ✢ * ✶ ✻ ✽` and back, and a random verb that changes at 2s, 3s, 5s and then every 5s,
/// decoding into place one character at a time. Everything follows from the time since the turn
/// began, so the row keeps no state, and it redraws only on its own schedule.
struct SpinnerRow: View {
    let since: Date
    /// Claude's list includes "Clauding"; a Codex chat leaves it out.
    let claude: Bool
    /// Said instead of a random verb ("Compacting").
    var word: String? = nil
    @Environment(\.spinnerTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hiddenTab) private var hidden
    @StateObject private var shown = Local(false)

    var body: some View {
        TimelineView(Schedule(since: since, still: reduceMotion, paused: hidden, verbs: verbs)) { context in
            let t = max(0, context.date.timeIntervalSince(since))
            HStack(spacing: 0) {
                Text(reduceMotion ? "✻" : Self.glyph(t))
                    .font(TextStyle.spinnerGlyph)
                    .foregroundStyle(Theme.spinnerGlyph(tint))
                    .frame(width: Size.spinnerGlyphBox)
                Text((word ?? Self.word(t, verbs: verbs, seed: seed, decode: !reduceMotion)) + "...")
                    .font(TextStyle.spinnerVerb)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.leading, Layout.Timeline.indent - Size.spinnerGlyphBox)
            }
        }
        .frame(height: Size.spinnerRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.spinnerTop)
        .opacity(shown.value ? 1 : 0)
        .onAppear { withAnimation(Motion.rowFadeIn) { shown.value = true } }
    }

    private var verbs: [String] { claude ? Self.verbs : Self.verbs.filter { $0 != "Clauding" } }
    private var seed: Int { Int(since.timeIntervalSinceReferenceDate * 1000) }

    // MARK: Glyph

    private static let glyphs = ["·", "✢", "*", "✶", "✻", "✽"]
    /// Ping-pong: · ✢ * ✶ ✻ ✽ ✽ ✻ ✶ * ✢ ·
    private static let cycle = glyphs + glyphs.reversed()

    static func glyph(_ t: TimeInterval) -> String {
        cycle[Int(t / Motion.spinnerFrame) % cycle.count]
    }

    // MARK: Verb

    /// The extension's list (`jE1`, 2.1.304).
    static let verbs = [
        "Accomplishing", "Actioning", "Actualizing", "Baking", "Booping", "Brewing", "Calculating", "Cerebrating",
        "Channeling", "Churning", "Clauding", "Coalescing", "Cogitating", "Computing", "Combobulating", "Concocting",
        "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Deciphering", "Deliberating",
        "Determining", "Discombobulating", "Doing", "Effecting", "Elucidating", "Enchanting", "Envisioning",
        "Finagling", "Flibbertigibbeting", "Forging", "Forming", "Frolicking", "Generating", "Germinating", "Hatching",
        "Herding", "Honking", "Ideating", "Imagining", "Incubating", "Inferring", "Manifesting", "Marinating",
        "Meandering", "Moseying", "Mulling", "Mustering", "Noodling", "Percolating", "Perusing", "Philosophizing",
        "Pontificating", "Pondering", "Processing", "Puttering", "Puzzling", "Reticulating", "Ruminating",
        "Schlepping", "Shimmying", "Simmering", "Smooshing", "Spelunking", "Spinning", "Stewing", "Sussing",
        "Synthesizing", "Thinking", "Tinkering", "Transmuting", "Unfurling", "Unraveling", "Vibing", "Wandering",
        "Whirring", "Wibbling", "Working", "Wrangling",
    ]

    /// When the k-th word appears: 0, 2, 3, 5, then every 5s.
    nonisolated static func swapTime(_ k: Int) -> TimeInterval {
        switch k {
        case 0: 0
        case 1: 2
        case 2: 3
        default: 5 * Double(k - 2)
        }
    }

    nonisolated static func swapIndex(_ t: TimeInterval) -> Int {
        if t < 2 { return 0 }
        if t < 3 { return 1 }
        if t < 5 { return 2 }
        return 2 + Int(t / 5)
    }

    /// The k-th word: a fixed pseudo-random pick per turn, never the same word twice in a row.
    static func verb(_ k: Int, verbs: [String], seed: Int) -> String {
        var index = mix(seed, k) % verbs.count
        if k > 0, index == mix(seed, k - 1) % verbs.count { index = (index + 1) % verbs.count }
        return verbs[index]
    }

    /// The word at time t. A new word decodes over the old one: the cursor `▌` walks left to
    /// right one character per `decodeFrame`, the two characters after it are random `.` `_` or
    /// the target, and the target lands behind it. Both are padded to the longer, so the width
    /// doesn't change while it decodes.
    static func word(_ t: TimeInterval, verbs: [String], seed: Int, decode: Bool) -> String {
        let k = swapIndex(t)
        let target = Array(verb(k, verbs: verbs, seed: seed))
        guard decode, k > 0 else { return String(target) }
        let cursor = Int((t - swapTime(k)) / Motion.decodeFrame)
        let old = Array(verb(k - 1, verbs: verbs, seed: seed))
        let width = max(old.count, target.count)
        guard cursor < width + 3 else { return String(target) }
        var out = ""
        for i in 0..<width {
            let goal: Character = i < target.count ? target[i] : " "
            if i < cursor {
                out.append(goal)
            } else if i == cursor {
                out.append("▌")
            } else if i <= cursor + 2 {
                out.append(["." as Character, "_", goal][mix(seed &+ cursor, i) % 3])
            } else {
                out.append(i < old.count ? old[i] : " ")
            }
        }
        // Trailing padding goes once the word has landed.
        return cursor >= width ? String(target) : out
    }

    private static func mix(_ a: Int, _ b: Int) -> Int {
        var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(b)) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Int(x % UInt64(Int.max))
    }

    /// Redraws every `decodeFrame` while a word decodes, else every `spinnerFrame` for the glyph;
    /// under reduced motion, only when the word changes.
    private struct Schedule: TimelineSchedule {
        let since: Date
        let still: Bool
        /// Under another tab: no frames at all.
        let paused: Bool
        let verbs: [String]

        func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            var date = start
            return AnyIterator {
                if paused { return nil }
                let t = date.timeIntervalSince(since)
                let step: TimeInterval
                if still {
                    let k = SpinnerRow.swapIndex(t)
                    step = max(0.05, SpinnerRow.swapTime(k + 1) - t)
                } else {
                    let k = SpinnerRow.swapIndex(t)
                    let decoding = k > 0 && t - SpinnerRow.swapTime(k) < Double(20) * Motion.decodeFrame
                    step = decoding ? Motion.decodeFrame : Motion.spinnerFrame
                }
                date = date.addingTimeInterval(step)
                return date
            }
        }
    }
}

/// The spinner glyph's colour: the chat's mode tint (nil for the neutral mode).
struct SpinnerTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var spinnerTint: Color? {
        get { self[SpinnerTintKey.self] }
        set { self[SpinnerTintKey.self] = newValue }
    }
}

/// Consecutive read-only tool calls as one item: "Explored  4 ›" (look.md §12).
struct ExploredItem: View {
    let calls: Int
    let open: Bool
    let toggle: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text("Explored").font(TextStyle.body).foregroundStyle(Theme.text)
                Text("\(calls)").font(TextStyle.toolName).foregroundStyle(Theme.liveCount).padding(.leading, Space.sm)
                Disclosure(isOpen: open).foregroundStyle(Theme.tertiary).padding(.leading, Space.xxs)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .opacity(hovered.value ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityHint(Text(open ? "Hides the reads" : "Shows the reads"))
    }
}

/// The one row at the top while there's more history above (look.md phase 08 §14, phase 10 §5):
/// "──── Load earlier turns ────", or "Load earlier conversation" once the shown history is
/// all in view and a compaction hides more. A plain button; while it loads, it says so.
struct LoadEarlierRow: View {
    let label: String
    var loading: String?
    let load: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: load) {
            HStack(spacing: Space.xl) {
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                Text(loading ?? label)
                    .font(TextStyle.label)
                    .foregroundStyle(hovered.value && loading == nil ? Theme.text : Theme.secondary)
                    .fixedSize()
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            }
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading != nil)
        .onHover { hovered.value = $0 }
        .padding(.bottom, Space.md)
    }
}

/// A quiet line across the transcript, the load row's geometry: "Conversation compacted ·
/// 14:32", "Forked from "…"". Not a button, except a fork's line while its original chat is
/// open: then its label switches to that chat (`secondary`, `text` under the pointer).
struct DividerRow: View {
    let text: String
    var open: (() -> Void)?
    /// The button's help; a plain line's, when it has one.
    var help: String?
    @StateObject private var hovered = Local(false)

    var body: some View {
        HStack(spacing: Space.xl) {
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            if let open {
                Button(action: open) { label(hovered.value ? Theme.text : Theme.secondary) }
                    .buttonStyle(.plain)
                    .onHover { hovered.value = $0 }
                    .help(help ?? "Open original")
            } else {
                label(Theme.tertiary).help(help ?? "")
            }
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
        .padding(.vertical, Space.sm)
    }

    private func label(_ color: Color) -> some View {
        Text(text)
            .font(TextStyle.label)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// The user changed the mode between turns (look.md §8): the divider's geometry, with the mode's
/// icon and name in its rung's colour (`tertiary` for a neutral mode). Not a button.
struct ModeDivider: View {
    let mode: ModeMark

    var body: some View {
        HStack(spacing: Space.xl) {
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            HStack(spacing: Space.xs) {
                mode.icon(Size.modeMarkIcon)
                Text(mode.label).font(TextStyle.label).lineLimit(1)
            }
            .foregroundStyle(mode.tint ?? Theme.tertiary)
            .fixedSize()
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
        .padding(.vertical, Space.sm)
    }
}

/// The agent changed the mode: "Entered Plan", "Plan approved · Edit automatically", "Left
/// Plan", the mode's name in its rung's colour. Its dot is the mode's icon (`TimelineDot.mode`).
struct ModeItemText: View {
    let lead: String
    let mode: ModeMark

    var body: some View {
        (Text(lead + " ").foregroundStyle(Theme.secondary) + Text(mode.label).foregroundStyle(mode.tint ?? Theme.secondary))
            .font(TextStyle.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a compaction kept (look.md §5): "Summary from Claude", then the summary as a quiet
/// quote (a rule at its left, secondary text, no box), collapsed like a long message with
/// "Show full summary". Copy takes the whole summary, also while it's collapsed.
struct CompactionSummary: View {
    let entry: TranscriptStore.Entry
    let expanded: Bool
    let actions: TranscriptActions
    /// Its laid-out lines, from an estimate until measured.
    @StateObject private var lines: Local<Int>

    init(entry: TranscriptStore.Entry, expanded: Bool, actions: TranscriptActions) {
        self.entry = entry
        self.expanded = expanded
        self.actions = actions
        let text = entry.text
        _lines = StateObject(wrappedValue: Local(max(text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }, text.utf8.count / Layout.Timeline.charsPerLine)))
    }

    private var collapsible: Bool { lines.value >= Layout.Timeline.collapseFrom }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(entry.result ?? "Summary from Claude")
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .top, spacing: Space.lg) {
                Rectangle().fill(Theme.timelineLine).frame(width: Stroke.quote)
                VStack(alignment: .leading, spacing: 0) {
                    MessageText(
                        text: entry.text, lines: collapsible && !expanded ? Layout.Timeline.collapsedLines : nil,
                        fade: Size.collapseFade * Zoom.shared.scale, ground: Theme.background, color: Theme.secondary
                    ) { lines.value = $0 }
                    if collapsible {
                        HStack {
                            Spacer(minLength: 0)
                            MessageToggle(expanded: expanded, title: "Show full summary") {
                                actions.toggle(MessageHeader.expandKey(entry))
                            }
                        }
                        .padding(.top, Space.messageToggle)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Space.sm)
        .padding(.bottom, Layout.Timeline.itemPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
        }
    }
}

/// A message sent while the turn runs (look.md §10): the user's box at 60%, with "Queued" under
/// it, until the CLI takes it.
struct QueuedMessage: View {
    let entry: TranscriptStore.Entry
    let actions: TranscriptActions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            MessageHeader(entry: entry, open: true, actions: actions)
                .padding(.vertical, -Layout.Timeline.itemPadding)
                .opacity(Theme.queuedOpacity)
            Text("Queued").font(TextStyle.caption).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, Space.sm / 2)
        .storyID(StoryID.Composer.queued(entry.id))
    }
}
