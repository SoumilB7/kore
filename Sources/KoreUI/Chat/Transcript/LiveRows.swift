import AppKit
import Combine
import SwiftUI

/// The running turn's last row, as in the Claude Code extension (look.md §12): a glyph cycling
/// `· ✢ * ✶ ✻ ✽` and back, and a random verb that changes at 2s, 3s, 5s and then every 5s,
/// decoding into place one character at a time. Everything follows from the time since the turn
/// began. One-shot sleeps update its text only at the next glyph, decode or word boundary.
struct SpinnerRow: View {
    let since: Date
    /// Claude's list includes "Clauding"; a Codex chat leaves it out.
    let claude: Bool
    /// Said instead of a random verb ("Compacting").
    var word: String? = nil
    /// Offline or stalled, it holds still with ⚠; stalled, it offers Retry and Stop.
    var connection: Connection = .ok
    var retry: () -> Void = {}
    var stop: () -> Void = {}
    @Environment(\.spinnerTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hiddenTab) private var hidden
    @StateObject private var shown = Local(false)
    @StateObject private var visible = Local(false)
    @StateObject private var clock = SpinnerClock()

    var body: some View {
        if connection.stuck {
            stuck
        } else {
            moving
        }
    }

    /// Nothing to animate while nothing can arrive: ⚠, what's wrong, and when stalled the way out.
    private var stuck: some View {
        HStack(spacing: 0) {
            Text("⚠")
                .font(TextStyle.spinnerGlyph)
                .foregroundStyle(Theme.warning)
                .frame(width: Size.spinnerGlyphBox)
            Text(word ?? "")
                .font(TextStyle.spinnerVerb)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.leading, Layout.Timeline.indent - Size.spinnerGlyphBox)
            if connection == .stalled {
                HStack(spacing: Space.sm) {
                    Button("Retry", action: retry).smallButton(prominent: true)
                        .storyID(StoryID.Transcript.stalledRetry)
                    Button("Stop", action: stop).smallButton()
                        .storyID(StoryID.Transcript.stalledStop)
                }
                .padding(.leading, Space.md)
            }
        }
        .frame(height: Size.spinnerRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.spinnerTop)
    }

    private var moving: some View {
        let configuration = SpinnerConfiguration(since: since, claude: claude, word: word,
                                                 reducedMotion: reduceMotion, paused: hidden || !visible.value)
        let frame = clock.frame(for: configuration)
        return HStack(spacing: 0) {
            Text(frame.glyph)
                .font(TextStyle.spinnerGlyph)
                .foregroundStyle(Theme.spinnerGlyph(tint))
                .frame(width: Size.spinnerGlyphBox)
            Text(frame.word)
                .font(TextStyle.spinnerVerb)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.leading, Layout.Timeline.indent - Size.spinnerGlyphBox)
        }
        .frame(height: Size.spinnerRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.spinnerTop)
        .opacity(shown.value ? 1 : 0)
        .onAppear { withAnimation(Motion.rowFadeIn) { shown.value = true } }
        .background(SpinnerVisibility { visible.value = $0 })
        .task(id: configuration) { await clock.run(configuration) }
    }

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

}

struct SpinnerFrame: Equatable, Sendable {
    let glyph: String
    let word: String
}

struct SpinnerConfiguration: Equatable, Sendable {
    let since: Date
    let claude: Bool
    var word: String?
    var reducedMotion = false
    var paused = false

    @MainActor private var verbs: [String] {
        claude ? SpinnerRow.verbs : SpinnerRow.verbs.filter { $0 != "Clauding" }
    }
    private var seed: Int { Int(since.timeIntervalSinceReferenceDate * 1000) }

    @MainActor func frame(at date: Date) -> SpinnerFrame {
        let time = max(0, date.timeIntervalSince(since))
        return SpinnerFrame(glyph: reducedMotion ? "✻" : SpinnerRow.glyph(time),
                            word: (word ?? SpinnerRow.word(time, verbs: verbs, seed: seed, decode: !reducedMotion)) + "...")
    }

    /// Absolute deadlines avoid drift, and a late wake renders the current frame instead of
    /// replaying missed frames. Reduce Motion with a fixed word has nothing left to schedule.
    @MainActor func nextUpdate(after date: Date) -> Date? {
        guard !paused else { return nil }
        let time = max(0, date.timeIntervalSince(since))
        let index = SpinnerRow.swapIndex(time)
        var next = word == nil ? SpinnerRow.swapTime(index + 1) : .infinity
        if !reducedMotion {
            func boundary(_ step: TimeInterval, from origin: TimeInterval = 0) -> TimeInterval {
                // Roundoff at an exact boundary must not schedule the same instant again.
                origin + (floor((time - origin) / step + 0.000_001) + 1) * step
            }
            next = min(next, boundary(Motion.spinnerFrame))
            if word == nil, index > 0 {
                let start = SpinnerRow.swapTime(index)
                let width = max(SpinnerRow.verb(index, verbs: verbs, seed: seed).count,
                                SpinnerRow.verb(index - 1, verbs: verbs, seed: seed).count)
                // Match the decoder's final guard, including its trailing completion steps.
                // Equal settled frames are not republished by SpinnerClock.
                if time < start + Double(width + 3) * Motion.decodeFrame {
                    next = min(next, boundary(Motion.decodeFrame, from: start))
                }
            }
        }
        guard next.isFinite else { return nil }
        return max(since.addingTimeInterval(next), date.addingTimeInterval(0.001))
    }
}

/// SwiftUI owns the task lifetime. Only distinct visible text is published; no display-link
/// or TimelineView remains active between these cancellable sleeps.
@MainActor
final class SpinnerClock: ObservableObject {
    @Published private(set) var current: SpinnerFrame?
    private var configuration: SpinnerConfiguration?
    private var generation = 0

    func frame(for configuration: SpinnerConfiguration) -> SpinnerFrame {
        self.configuration == configuration ? (current ?? configuration.frame(at: .now)) : configuration.frame(at: .now)
    }

    func run(_ configuration: SpinnerConfiguration, now: () -> Date = Date.init,
             sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let own = generation
        self.configuration = configuration
        while !Task.isCancelled, generation == own {
            let date = now()
            let frame = configuration.frame(at: date)
            if current != frame { current = frame }
            guard let next = configuration.nextUpdate(after: date) else { return }
            do { try await sleep(.seconds(max(next.timeIntervalSince(date), 0.001))) }
            catch { return }
        }
    }
}

/// Window visibility changes are rare events. Reporting on the next main turn avoids changing
/// SwiftUI state during native-view attachment; teardown cancels any queued report.
private struct SpinnerVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> SpinnerVisibilityView { SpinnerVisibilityView(changed: changed) }
    func updateNSView(_ view: SpinnerVisibilityView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: SpinnerVisibilityView, coordinator: ()) { view.stop() }
}

final class SpinnerVisibilityView: NSView {
    var changed: (Bool) -> Void
    private var stopped = false

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                                                  name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        reportLater()
    }
    override func viewDidHide() { super.viewDidHide(); reportLater() }
    override func viewDidUnhide() { super.viewDidUnhide(); reportLater() }
    @objc private func windowChanged(_ note: Notification) { reportLater() }

    private func reportLater() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.changed(self.window?.occlusionState.contains(.visible) == true && !self.isHiddenOrHasHiddenAncestor)
        }
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
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
        .koreContextMenu("summary") {
            [OptionItem("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }]
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
