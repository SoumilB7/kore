import SwiftUI

/// The chat's user messages as ticks on its right edge: bright for the one being read, plain for
/// those loaded, dim for those not yet. The pointer over a tick shows its message; a click goes
/// there, loading it first if it has to. Plain shapes, at most `Size.railMost`, drawn again only
/// when a message crosses the top, a list changes or the pointer moves to another tick. Not a
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
    /// What the run of ticks is centred on: it holds still under the pointer, so one tick up is
    /// one tick up, and catches up when the pointer leaves.
    @StateObject private var runAround = Held<Int?>(nil)
    /// The rail last drawn and the message it lit, for a storyline.
    @StateObject private var drawn = Held<(layout: Layout, current: Int?)?>(nil)
    /// The last jump's second aim, which the next jump replaces.
    @StateObject private var aiming = Held<Task<Void, Never>?>(nil)
    /// The one on its way in from disk.
    @StateObject private var loading = Local<Int?>(nil)

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                height.value = $0
                reading.height = $0
            }
            .overlay(alignment: .trailing) {
                let marks = store.messageMarks
                if marks.count > 1, height.value > 0 {
                    let layout = Layout(count: marks.count, room: height.value - 2 * Size.railMargin, around: around(marks))
                    rail(marks, layout).offset(y: Self.drop(growth: store.composerGrowth, room: height.value, rail: layout.height))
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

    /// Which ticks show and where: all of them up to `Size.railMost`. Past that, the chat's first
    /// and last and a run around the message being read, so either end is a click away and each
    /// click on the run's end moves it on.
    struct Layout {
        let shown: [Int]
        let spacing: CGFloat

        init(count: Int, room: CGFloat, around: Int?) {
            if count <= Size.railMost {
                shown = Array(0..<count)
            } else {
                let run = Size.railMost - 2
                let start = min(max((around ?? count - 1) - run / 2, 1), count - 1 - run)
                shown = [0] + Array(start..<(start + run)) + [count - 1]
            }
            spacing = shown.count > 1 ? min(Size.railSpacing, room / CGFloat(shown.count - 1)) : Size.railSpacing
        }

        /// The rail's height: the ticks, and room for the pointer past each end. `y` and
        /// `index(atY:)` are both from its top, so a tick lights where it's drawn.
        var height: CGFloat { CGFloat(max(shown.count - 1, 0)) * spacing + Size.railStroke + 2 * Size.railSpacing }

        func y(_ place: Int) -> CGFloat { CGFloat(place) * spacing + Size.railStroke / 2 + Size.railSpacing }

        /// Where a message is among the ticks, when it's shown.
        func place(of index: Int) -> Int? { shown.firstIndex(of: index) }

        func index(atY y: CGFloat) -> Int {
            let nearest = Int(((y - self.y(0)) / spacing).rounded())
            return shown[min(max(nearest, 0), shown.count - 1)]
        }

        /// A tick next to a gap in the list fades, saying there's more between.
        func fade(_ place: Int) -> Double {
            func gap(_ a: Int, _ b: Int) -> Bool { shown.indices.contains(a) && shown.indices.contains(b) && shown[b] - shown[a] > 1 }
            var nearest = Size.railFade
            for distance in 0..<Size.railFade where gap(place - distance - 1, place - distance) || gap(place + distance, place + distance + 1) {
                nearest = distance
                break
            }
            return min(Double(nearest + 1) / Double(Size.railFade), 1)
        }
    }

    private func rail(_ marks: [TranscriptStore.MessageMark], _ layout: Layout) -> some View {
        let reading = current(marks)
        drawn.value = (layout, reading)
        let pointed = hovered.value
        let coming = loading.value
        return ZStack(alignment: .topTrailing) {
            ForEach(layout.shown.indices, id: \.self) { place in
                let index = layout.shown[place]
                Self.tick
                    .fill(Self.color(marks[index], lit: index == reading || index == pointed || index == coming))
                    .frame(width: Self.length(place, index, layout, current: reading, hover: pointed) + Size.railStroke / 2, height: Size.railStroke)
                    .opacity(layout.fade(place))
                    .offset(y: layout.y(place) - Size.railStroke / 2)
            }
        }
        .frame(width: Size.railWidth, height: layout.height, alignment: .topTrailing)
        // Its column clear of what runs under it (a wide box, the page pinched in).
        .background(Self.backing)
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
                    .offset(x: -(Size.railWidth + Size.railCardGap), y: cardTop(at: layout.y(layout.place(of: pointed) ?? 0), layout))
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
                ticks: { drawn.value.map { rail in rail.layout.shown.enumerated().map { ($1, rail.layout.y($0)) } } ?? [] },
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

    /// The transcript's own background, fading in from the rail's inner edge.
    private static let backing = LinearGradient(
        stops: [.init(color: Theme.background.opacity(0), location: 0), .init(color: Theme.background, location: 0.3)],
        startPoint: .leading, endPoint: .trailing)

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

    /// The message being read: where the rows are says (`MessageReading`), or the end's. The
    /// end's only while the last message's row is on screen too: the view's following flag is
    /// also set by what pins the end (a send's glide, a view built again, a pinch ending, a long
    /// message closing) before the rows get there, and alone it lit the last message mid-chat.
    private func current(_ marks: [TranscriptStore.MessageMark]) -> Int? {
        guard !marks.isEmpty else { return nil }
        guard let index = reading.index else { return marks.count - 1 }
        return atEnd && reading.lastShown ? marks.count - 1 : index
    }

    private func around(_ marks: [TranscriptStore.MessageMark]) -> Int? {
        if hovered.value == nil { runAround.value = current(marks) }
        return runAround.value
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
            // The one asked for is the same message counted from the end once it's in: a page
            // can bring more before it (all a compaction left on disk, say).
            let fromEnd = marks.count - 1 - index
            Task {
                await actions.loadEarlierTurns(turns)
                loading.value = nil
                let now = store.messageMarks
                let asked = now.count - 1 - fromEnd
                guard now.indices.contains(asked), case .built(let section) = now[asked].place else {
                    if let first = store.firstUserMessage { afterLayout(first.uuidString) }
                    return
                }
                afterLayout(String(section.dropFirst(2)))
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
    /// shift it (all the more while an answer streams in), so it's aimed again once they've been,
    /// until the row's top is at the top.
    private func go(_ row: String) {
        scrollTo(row)
        aiming.value?.cancel()
        aiming.value = Task {
            for _ in 0..<Self.aims {
                try? await Task.sleep(for: Self.settle)
                guard !Task.isCancelled else { return }
                scrollTo(row)
                if reading.landed(row) { break }
            }
            tracker.landed()
        }
    }

    private static let settle: Duration = .milliseconds(120)
    private static let aims = 8
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
    /// The reader is at the last message: its row is on screen, or it left the list off the top,
    /// or, never seen, no other message's row is on screen.
    @Published private(set) var lastShown = false
    /// The view's height.
    var height: CGFloat = 0 {
        didSet { if height != oldValue { update() } }
    }
    /// The view follows the end now (the timeline's; no update of its own): the last
    /// message's row leaving then went off the top, wherever it last was (a send's glide carries it
    /// off from mid-view in one move).
    var following: Bool { isFollowing() }
    /// The timeline's own flag, read live (a jump drops it before its rows go).
    var isFollowing: () -> Bool = { false }
    private var tops: [String: CGFloat] = [:]
    /// When each top was last reported, to tell a stale one (`dropStale`).
    private var stamps: [String: Int] = [:]
    private var clock = 0
    /// Each message row's place among the scroller's marks once its top reaches the top (the
    /// user's own, or a peer's: the user's last before it), and its turn's above it.
    private var at: [String: Int] = [:]
    private var before: [String: Int] = [:]
    private var marks: [TranscriptStore.MessageMark] = []
    /// The message being read, by what it is.
    private var read: TranscriptStore.MessageMark.Place?
    /// The last mark's row, when it's built, and whether it last left the list off the top.
    private var lastRow: String?
    private var lastLeftAbove: Bool?

    /// The marks, and the built sections' ids in order (`s-<row>`): a section with no mark of its
    /// own (a peer's message) reads as the last mark before it.
    func list(_ marks: [TranscriptStore.MessageMark], sections: [String] = []) {
        self.marks = marks
        let end: String? = if case .built(let section) = marks.last?.place { String(section.dropFirst(2)) } else { nil }
        // A new last message while the end is followed (a send): the view goes on past it as the
        // reply comes, so it's read till another message's row shows (its own row may never
        // report: the reply can carry it off before it's laid out on screen).
        if end != lastRow { (lastRow, lastLeftAbove) = (end, following && lastRow != nil ? true : nil) }
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
        if let read, let place = marks.firstIndex(where: { $0.place == read }), place != index {
            ScrollLog.write("reading", "kept \(index ?? -1)->\(place) marks=\(marks.count)")
            index = place
        }
        update()
    }

    /// A message row is at the top of the view, where a jump puts it.
    func landed(_ row: String) -> Bool { tops[row].map { abs($0) <= Size.railReadLine } ?? false }

    /// A message row's top in the view; nil once it's gone from the list.
    func moved(_ row: String, _ top: CGFloat?) {
        if row == lastRow, top == nil, let was = tops[row] { lastLeftAbove = was < 0 || following }
        // An earlier message's row gone while the end is followed, the last message's row never
        // reported (a reply can carry it off before it's laid out on screen): the view is past
        // every row that did, on its way to the end, where the last message is. Another row still
        // on screen gives the reading back to the rows (`update`).
        if row != lastRow, top == nil, following, tops[row] != nil, let lastRow, tops[lastRow] == nil, stamps[lastRow] == nil {
            lastLeftAbove = true
        }
        tops[row] = top
        clock &+= 1
        stamps[row] = top == nil ? nil : clock
        update()
    }

    /// The scroll view was built again (the blank check, a tab coming back): the old view's rows
    /// went with it, none saying so. Their tops are dropped; the new view's rows report their own.
    /// The message read stays lit until they do.
    func rowsGone() {
        guard !tops.isEmpty || lastLeftAbove != nil else { return }
        ScrollLog.write("reading", "rows gone tops=\(tops.count) index=\(index ?? -1)")
        tops = [:]
        stamps = [:]
        lastLeftAbove = nil
        if let lastRow, let place = at[lastRow], index == place { lastLeftAbove = true }
    }

    /// A row's view can leave without saying so (a list built again, a page read in above, a jump
    /// far off), its last top left behind: after a jump to the first message, message 25's old top
    /// just under the read line lit it (a narrow window's heights put it nearest). Tops follow
    /// the chat's order on screen; where two disagree, the one reported earlier is stale.
    private func dropStale() {
        struct Placed {
            let row: String
            let top: CGFloat
            let place: Int
            let stamp: Int
        }
        var placed: [Placed] = []
        for (row, top) in tops {
            if let place = at[row] { placed.append(Placed(row: row, top: top, place: place, stamp: stamps[row] ?? 0)) }
        }
        placed.sort { a, b in a.place != b.place ? a.place < b.place : a.top < b.top }
        var kept: [Placed] = []
        for row in placed {
            var stale = false
            while let last = kept.last, last.place < row.place, last.top > row.top {
                if row.stamp < last.stamp {
                    stale = true
                    break
                }
                kept.removeLast()
                tops[last.row] = nil
                stamps[last.row] = nil
            }
            if stale {
                tops[row.row] = nil
                stamps[row.row] = nil
            } else {
                kept.append(row)
            }
        }
    }

    private func update() {
        dropStale()
        // Another message's row on screen and the last's not drawn: the reader isn't at the
        // last, whichever way it left (a jump up from the end left it "above" for good). With
        // none on screen after that, which side it's on is unknown again: the end's following
        // says (a long last answer read at the end).
        let otherShown = tops.contains { $0.key != lastRow && $0.value >= 0 && $0.value < height }
        if otherShown, lastRow.flatMap({ tops[$0] }) == nil { lastLeftAbove = nil }
        let shown =
            if let top = lastRow.flatMap({ tops[$0] }) { top < height } else if let lastLeftAbove { lastLeftAbove } else { !otherShown }
        if shown != lastShown { lastShown = shown }
        // The last message's row gone off the top with no other on screen: the reader is in its
        // turn (a long answer streaming in under it), followed or not.
        if lastLeftAbove == true, !otherShown, let row = lastRow, tops[row] == nil, let place = at[row] {
            if place != index {
                ScrollLog.write("reading", "index \(index ?? -1)->\(place) in the last turn")
                index = place
            }
            if marks.indices.contains(place) { read = marks[place].place }
            return
        }
        // The row past the read line nearest it: the same as the latest one past it while the
        // tops are the rows' own, and not one whose top is left from a list built again since.
        var above: (place: Int, top: CGFloat)?
        var first: (top: CGFloat, row: String)?
        for (row, top) in tops {
            guard let place = at[row] else { continue }
            if first.map({ top < $0.top }) ?? true { first = (top, row) }
            if top <= Size.railReadLine, above.map({ top > $0.top || top == $0.top && place > $0.place }) ?? true { above = (place, top) }
        }
        guard let first, let now = above?.place ?? before[first.row] else {
            ScrollLog.write("reading", "none tops=\(tops.count) mapped=\(tops.keys.filter { at[$0] != nil }.count) index=\(index ?? -1)")
            return
        }
        if now != index {
            ScrollLog.write(
                "reading",
                "index \(index ?? -1)->\(now) above=\(above.map { "\($0.place)@\(Int($0.top))" } ?? "-") first=\(at[first.row] ?? -1)@\(Int(first.top)) height=\(Int(height))")
            index = now
        }
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
