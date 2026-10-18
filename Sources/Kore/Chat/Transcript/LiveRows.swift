import SwiftUI

/// The running turn's last row, as in the Claude Code extension (look.md §12): a glyph cycling
/// `· ✢ * ✶ ✻ ✽` and back, and a random verb that changes at 2s, 3s, 5s and then every 5s,
/// decoding into place one character at a time. Everything follows from the time since the turn
/// began, so the row keeps no state, and it redraws only on its own schedule.
struct SpinnerRow: View {
    let since: Date
    /// Claude's list includes "Clauding"; a Codex chat leaves it out.
    let claude: Bool
    @Environment(\.spinnerTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var shown = Local(false)

    var body: some View {
        TimelineView(Schedule(since: since, still: reduceMotion, verbs: verbs)) { context in
            let t = max(0, context.date.timeIntervalSince(since))
            HStack(spacing: 0) {
                Text(reduceMotion ? "✻" : Self.glyph(t))
                    .font(TextStyle.spinnerGlyph)
                    .foregroundStyle(Theme.spinnerGlyph(tint))
                    .frame(width: Size.spinnerGlyphBox)
                Text(Self.word(t, verbs: verbs, seed: seed, decode: !reduceMotion) + "...")
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
        let verbs: [String]

        func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            var date = start
            return AnyIterator {
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
        .help(open ? "Hide these reads" : "Show these reads")
    }
}

/// Above the shown turns while earlier ones exist: "──── Load earlier turns ────" (T3 Code).
struct LoadEarlierRow: View {
    let load: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: load) {
            HStack(spacing: Space.md) {
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                Text("Load earlier turns")
                    .font(TextStyle.caption)
                    .foregroundStyle(hovered.value ? Theme.secondary : Theme.tertiary)
                    .fixedSize()
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            }
            .padding(.vertical, Layout.Timeline.itemPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Show 20 more turns")
    }
}
