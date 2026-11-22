import SwiftUI

/// The chat's user messages as ticks on its right edge, the chat from its first message at the
/// rail's top to its last at its bottom: bright for the one being read, plain for those loaded,
/// dim for those not yet. The pointer over the rail shows the message at its place; a click goes
/// there, loading it first if it has to. Plain shapes, at most `Size.railMost`, drawn again only
/// when a message crosses the top, a list changes or the pointer moves to another message. Not a
/// Canvas: its renderer holds about 50 MB of graphics memory while anything draws, whatever the
/// size of the canvas.
struct MessageRail: View {
    let store: TranscriptStore
    let tracker: StickyTracker
    @ObservedObject var reading: MessageReading
    /// Following the end: the last message is the one being read.
    let atEnd: Bool
    let actions: TranscriptActions
    /// Scrolls a section to the top, the reader's place now.
    let scrollTo: (String) -> Void

    @StateObject private var height = Local<CGFloat>(0)
    @StateObject private var hovered = Local<Int?>(nil)
    @StateObject private var cardHeight = Local<CGFloat>(0)
    /// The rail last drawn and the message it lit, for a storyline.
    @StateObject private var drawn = Held<(layout: Layout, current: Int?)?>(nil)
    /// The last jump's second aim, which the next jump replaces.
    @StateObject private var aiming = Held<Task<Void, Never>?>(nil)
    /// The one on its way in from disk.
    @StateObject private var loading = Local<Int?>(nil)

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.value = $0 }
            .overlay(alignment: .trailing) {
                let marks = store.messageMarks
                if marks.count > 1, height.value > 0 {
                    let reading = current(marks)
                    let lit = [reading, hovered.value, loading.value].compactMap { $0 }
                    let layout = Layout(count: marks.count, room: height.value - 2 * Size.railMargin, lit: lit)
                    rail(marks, layout, reading).offset(y: Self.drop(growth: store.composerGrowth, room: height.value, rail: layout.height))
                }
            }
            .onChange(of: SectionsKey(store), initial: true) {
                reading.list(store.messageMarks, sections: store.sections.map(\.id))
                goToPending()
            }
            // The list of what isn't loaded: once there's something, then after each page.
            .task(id: store.earlierAvailable && !store.loadingEarlier) {
                if !store.loadingEarlier { await actions.readEarlierMessages() }
            }
    }

    /// How far the rail sits below the middle of what shows: half the composer's growth, so its
    /// middle stays where it was before the composer grew, and never past its room's margin.
    static func drop(growth: CGFloat, room: CGFloat, rail: CGFloat) -> CGFloat {
        guard growth > 0 else { return 0 }
        return min(growth / 2, max(0, (room - rail) / 2 - Size.railMargin))
    }

    /// Where each message's tick is: in order down the rail, one step apart, so the rail is the
    /// chat from its first message to its last and a tick's place says where its message is. The
    /// rail grows with the chat until it fills its room. Drawn: every tick while they're
    /// `Size.railSpacing` apart and no more than `Size.railMost`; past that every so many, evenly,
    /// the first and last always, and each lit one (being read, under the pointer, on its way in)
    /// at its own place, in place of the picked one nearest it. The pointer finds any message,
    /// drawn or not, so what lights under it is what a click opens.
    struct Layout {
        let count: Int
        /// From one message's tick to the next's.
        let step: CGFloat
        let shown: [Int]

        init(count: Int, room: CGFloat, lit: [Int] = []) {
            self.count = count
            let gaps = CGFloat(max(count - 1, 1))
            step = max(0, min(Size.railStepMost, room / gaps))
            let fit = Int(step * gaps / Size.railSpacing) + 1
            let most = min(count, max(min(Size.railMost, fit), 2))
            var shown = Array(0..<count)
            if most < count {
                // Every `every`th, so they're evenly apart; the last's own, with the one before it
                // left out when that's under half the way.
                let every = Int((Double(count - 1) / Double(most - 1)).rounded(.up))
                shown = Array(stride(from: 0, to: count - 1, by: every))
                if shown.count > 1, (count - 1 - shown[shown.count - 1]) * 2 < every { shown.removeLast() }
                shown.append(count - 1)
            }
            let lit = Set(lit.filter { (0..<count).contains($0) })
            for index in lit.sorted() where !shown.contains(index) {
                let picked = shown.indices.filter { $0 > 0 && $0 < shown.count - 1 && !lit.contains(shown[$0]) }
                if let nearest = picked.min(by: { abs(shown[$0] - index) < abs(shown[$1] - index) }) { shown[nearest] = index } else { shown.append(index) }
            }
            self.shown = shown.sorted()
        }

        /// The rail's height: the ticks, and room for the pointer past each end. `y` and
        /// `index(atY:)` are both from its top, so a tick lights where it's drawn.
        var height: CGFloat { CGFloat(max(count - 1, 0)) * step + Size.railStroke + 2 * Size.railSpacing }

        /// A message's tick, drawn or not.
        func y(_ index: Int) -> CGFloat { CGFloat(index) * step + Size.railStroke / 2 + Size.railSpacing }

        /// Where a message is among the drawn ticks, when it's drawn.
        func place(of index: Int) -> Int? { shown.firstIndex(of: index) }

        /// The message whose place is nearest.
        func index(atY y: CGFloat) -> Int {
            guard count > 1, step > 0 else { return 0 }
            return min(max(Int(((y - self.y(0)) / step).rounded()), 0), count - 1)
        }
    }

    private func rail(_ marks: [TranscriptStore.MessageMark], _ layout: Layout, _ reading: Int?) -> some View {
        drawn.value = (layout, reading)
        let pointed = hovered.value
        let coming = loading.value
        return ZStack(alignment: .topTrailing) {
            ForEach(layout.shown.indices, id: \.self) { place in
                let index = layout.shown[place]
                Self.tick
                    .fill(Self.color(marks[index], lit: index == reading || index == pointed || index == coming))
                    .frame(width: Self.length(place, index, layout, current: reading, hover: pointed) + Size.railStroke / 2, height: Size.railStroke)
                    .offset(y: layout.y(index) - Size.railStroke / 2)
            }
        }
        .frame(width: Size.railWidth, height: layout.height, alignment: .topTrailing)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let at): point(at: layout.index(atY: at.y))
            case .ended: point(at: nil)
            }
        }
        .onTapGesture { at in jump(layout.index(atY: at.y), marks) }
        .overlay(alignment: .topTrailing) {
            if let pointed, marks.indices.contains(pointed), let preview = preview(marks[pointed]) {
                RailCard(message: preview.message, answer: preview.answer, back: marks.count - pointed)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight.value = $0 }
                    .offset(x: -(Size.railWidth + Size.railCardGap), y: cardTop(at: layout.y(pointed), layout))
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, Size.railInset)
        .storyID(StoryID.Transcript.rail)
        .accessibilityElement()
        .accessibilityLabel("Messages")
        .accessibilityValue("\(marks.count)")
        .onAppear {
            guard StoryHost.installed else { return }
            let (store, hovered, drawn, height) = (store, hovered, drawn, height)
            store.storyRail = (
                jump: { [self] in jump($0, store.messageMarks) }, hover: { hovered.value = $0 },
                current: { drawn.value?.current },
                ticks: { drawn.value.map { rail in rail.layout.shown.map { ($0, rail.layout.y($0)) } } ?? [] },
                room: { height.value - 2 * Size.railMargin },
                click: { [self] y in if let layout = drawn.value?.layout { jump(layout.index(atY: y), store.messageMarks) } }
            )
        }
    }

    /// Centred on its tick, kept inside the transcript; the rail is centred in the transcript,
    /// and the card's offset is from the rail's top.
    private func cardTop(at y: CGFloat, _ layout: Layout) -> CGFloat {
        let railTop = (height.value - layout.height) / 2
        let lowest = max(height.value - cardHeight.value - Size.railMargin, Size.railMargin)
        return min(max(railTop + y - cardHeight.value / 2, Size.railMargin), lowest) - railTop
    }

    /// Round towards the transcript, square at the rail's edge.
    private static let tick = UnevenRoundedRectangle(topLeadingRadius: Size.railStroke / 2, bottomLeadingRadius: Size.railStroke / 2)

    private static func length(_ place: Int, _ index: Int, _ layout: Layout, current: Int?, hover: Int?) -> CGFloat {
        let resting = index == current ? Size.railTickCurrent : Size.railTick
        guard let hover, let pointed = layout.place(of: hover) else { return resting }
        return max(resting, Size.railTickHover - CGFloat(abs(place - pointed)) * Size.railTickHoverStep)
    }

    private static func color(_ mark: TranscriptStore.MessageMark, lit: Bool) -> Color {
        if lit { return Theme.railTickCurrent }
        if case .earlier = mark.place { return Theme.railTickUnloaded }
        return Theme.railTick
    }

    private func point(at index: Int?) {
        if hovered.value != index { hovered.value = index }
    }

    /// The message being read: where the rows are says (`MessageReading`), or the end's.
    private func current(_ marks: [TranscriptStore.MessageMark]) -> Int? {
        if atEnd || reading.index == nil { return marks.isEmpty ? nil : marks.count - 1 }
        return reading.index
    }

    private func preview(_ mark: TranscriptStore.MessageMark) -> (message: String, answer: String?)? {
        switch mark.place {
        case .built(let section): return store.messagePreview(section)
        case .held(let entry): return store.messagePreview("s-\(entry.uuidString)")
        case .earlier(let index): return store.earlierMarks.indices.contains(index) ? (store.earlierMarks[index].text, nil) : nil
        }
    }

    private func jump(_ index: Int, _ marks: [TranscriptStore.MessageMark]) {
        guard marks.indices.contains(index), loading.value == nil else { return }
        // A page is on its way (scrolling near the top asks for them too): the marks change when
        // it lands, the one asked for is the same message counted from the end.
        if store.loadingEarlier {
            let fromEnd = marks.count - 1 - index
            loading.value = index
            Task {
                while store.loadingEarlier { try? await Task.sleep(for: Self.pagePoll) }
                loading.value = nil
                let now = store.messageMarks
                jump(now.count - 1 - fromEnd, now)
            }
            return
        }
        switch marks[index].place {
        case .built(let section):
            go(String(section.dropFirst(2)))
        case .held(let entry):
            store.show(from: entry)
            afterLayout(entry.uuidString)
        case .earlier(let at):
            guard store.earlierMarks.indices.contains(at) else { return }
            let turns = store.earlierMarks[at].turns
            loading.value = index
            store.showAll()
            Task {
                await actions.loadEarlierTurns(turns)
                loading.value = nil
                // The page's first message is the one asked for.
                if let first = store.firstUserMessage { afterLayout(first.uuidString) }
            }
        }
    }

    private static let afterOpening: Duration = .milliseconds(300)

    /// The search's message, once what's loaded holds it. It isn't there yet: all that's left
    /// comes in, as one page.
    private func goToPending() {
        guard let pending = store.pendingMessage else { return }
        guard Date() < pending.until else {
            store.pendingMessage = nil
            return
        }
        guard let message = store.message(saying: pending.query) else {
            guard store.earlierAvailable, !store.loadingEarlier, !store.earlierMarks.isEmpty, let turns = store.earlierMarks.first?.turns else { return }
            store.showAll()
            Task { await actions.loadEarlierTurns(turns) }
            return
        }
        store.pendingMessage = nil
        // Past a just-opened chat's first layouts, which end at its end.
        Task {
            try? await Task.sleep(for: Self.afterOpening)
            store.show(from: message)
            afterLayout(message.uuidString)
        }
    }

    /// The row exists once the list has taken the new sections in.
    private func afterLayout(_ row: String) {
        DispatchQueue.main.async { DispatchQueue.main.async { go(row) } }
    }

    /// To the message's row. A far jump lands by estimated heights, and rows measured on the way
    /// shift it, so it's aimed once more when they've been.
    private func go(_ row: String) {
        scrollTo(row)
        aiming.value?.cancel()
        aiming.value = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            scrollTo(row)
            tracker.landed()
        }
    }

    private static let settle: Duration = .milliseconds(120)
    private static let pagePoll: Duration = .milliseconds(30)
}

/// Which message is being read, from where the message rows really are: the last whose top has
/// reached the top of the view, or, with none there yet, the one whose turn is above the first on
/// screen. Every message row counts, a peer's too: a peer's message reads as the user's last
/// before it, so a stretch of peers' messages past the user's last still reads as that one. The
/// message is kept by what it is, not its place, so marks arriving before it (a compacted chat's
/// earlier messages) keep its tick. Publishes only when it changes.
@MainActor
final class MessageReading: ObservableObject {
    @Published private(set) var index: Int?
    private var tops: [String: CGFloat] = [:]
    /// Each message row's place among the scroller's marks once its top reaches the top (the
    /// user's own, or a peer's: the user's last before it), and its turn's above it.
    private var at: [String: Int] = [:]
    private var before: [String: Int] = [:]
    private var marks: [TranscriptStore.MessageMark] = []
    /// The message being read, by what it is.
    private var read: TranscriptStore.MessageMark.Place?

    /// The marks, and the built sections' ids in order (`s-<row>`): a section with no mark of its
    /// own (a peer's message) reads as the last mark before it.
    func list(_ marks: [TranscriptStore.MessageMark], sections: [String] = []) {
        self.marks = marks
        at = [:]
        before = [:]
        var built: [String: Int] = [:]
        var last: Int?
        for (place, mark) in marks.enumerated() {
            if case .built(let section) = mark.place { built[section] = place } else { last = place }
        }
        let order = sections.isEmpty ? marks.compactMap { if case .built(let s) = $0.place { s } else { nil } } : sections
        for section in order where section.hasPrefix("s-") {
            let row = String(section.dropFirst(2))
            if let place = built[section] {
                at[row] = place
                before[row] = max(place - 1, 0)
                last = place
            } else if let last {
                at[row] = last
                before[row] = last
            }
        }
        // The one being read stays itself while the list around it changes.
        if let read, let place = marks.firstIndex(where: { $0.place == read }), place != index { index = place }
        update()
    }

    /// A message row's top in the view; nil once it's gone from the list.
    func moved(_ row: String, _ top: CGFloat?) {
        tops[row] = top
        update()
    }

    private func update() {
        var above: Int?
        var first: (top: CGFloat, row: String)?
        for (row, top) in tops {
            guard let place = at[row] else { continue }
            if first.map({ top < $0.top }) ?? true { first = (top, row) }
            if top <= Size.railReadLine, above.map({ place > $0 }) ?? true { above = place }
        }
        guard let first, let now = above ?? before[first.row] else { return }
        if now != index { index = now }
        if marks.indices.contains(now) { read = marks[now].place }
    }
}

/// What the reading's list follows: the marks, and the sections' ends and count (a peer's message
/// adds a section, no mark). Cheap to compare on every pass.
private struct SectionsKey: Equatable {
    let marks: [TranscriptStore.MessageMark]
    let count: Int
    let first: String?
    let last: String?

    @MainActor init(_ store: TranscriptStore) {
        marks = store.messageMarks
        count = store.sections.count
        first = store.sections.first?.id
        last = store.sections.last?.id
    }
}

/// A message under the pointer: its first words, how its turn ended when that's loaded, and where
/// it is from the end ("-3"), as `kore fork --at` takes it.
private struct RailCard: View {
    let message: String
    let answer: String?
    let back: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(Self.line(message, or: "Image"))
                    .font(Chrome.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("-\(back)")
                    .font(Chrome.label)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .storyID(StoryID.Transcript.railCount(back))
            }
            if let answer {
                Text(Self.line(answer, or: ""))
                    .font(Chrome.label)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(3)
            }
        }
        .padding(Space.lg)
        .frame(width: Size.railCard, alignment: .leading)
        .panel(.panel)
    }

    private static let shownCharacters = 240

    private static func line(_ text: String, or empty: String) -> String {
        let words = text.prefix(shownCharacters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? empty : words
    }
}
