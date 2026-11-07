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
    /// The tick last drawn lit, for a storyline.
    @StateObject private var drawnCurrent = Held<Int?>(nil)
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
                    rail(marks, Layout(count: marks.count, room: height.value - 2 * Size.railMargin, around: around(marks)))
                }
            }
            .onChange(of: store.messageMarks, initial: true) {
                reading.list(store.messageMarks)
                goToPending()
            }
            // The list of what isn't loaded: once there's something, then after each page.
            .task(id: store.earlierAvailable && !store.loadingEarlier) {
                if !store.loadingEarlier { await actions.readEarlierMessages() }
            }
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
        drawnCurrent.value = reading
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
                RailCard(message: preview.message, answer: preview.answer)
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
            let (store, hovered) = (store, hovered)
            store.storyRail = (
                jump: { [self] in jump($0, store.messageMarks) }, hover: { hovered.value = $0 },
                current: { [drawnCurrent] in drawnCurrent.value }
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
/// reached the top of the view, or, with none there yet, the one before the first on screen,
/// whose turn is what's above it. A long answer with no message on screen leaves it as it was.
/// Publishes only when it changes.
@MainActor
final class MessageReading: ObservableObject {
    @Published private(set) var index: Int?
    private var tops: [String: CGFloat] = [:]
    /// Each built message's place among the scroller's marks, by its row.
    private var places: [String: Int] = [:]

    func list(_ marks: [TranscriptStore.MessageMark]) {
        places = [:]
        for (place, mark) in marks.enumerated() {
            if case .built(let section) = mark.place { places[String(section.dropFirst(2))] = place }
        }
        update()
    }

    /// A message row's top in the view; nil once it's gone from the list.
    func moved(_ row: String, _ top: CGFloat?) {
        tops[row] = top
        update()
    }

    private func update() {
        var above: Int?
        var first: Int?
        for (row, top) in tops {
            guard let place = places[row] else { continue }
            if first.map({ place < $0 }) ?? true { first = place }
            if top <= Size.railReadLine, above.map({ place > $0 }) ?? true { above = place }
        }
        guard let first else { return }
        let now = above ?? max(first - 1, 0)
        if now != index { index = now }
    }
}

/// A message under the pointer: its first words, and how its turn ended when that's loaded.
private struct RailCard: View {
    let message: String
    let answer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Self.line(message, or: "Image"))
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
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
