import SwiftUI

/// The conversation as a timeline (look.md §2). Sections start at each user message, whose box
/// sticks to the top while its section scrolls by. Rows are built lazily and compare by value,
/// and only the last turns are built: "Load earlier turns" adds more above, keeping the view
/// still. Following the end works as in the Claude Code extension (live-streaming.md): within
/// 50pt of the bottom new content is pinned at once, for 2s after a send it glides, and once the
/// reader scrolls up nothing moves. A turn folding above the answer keeps the answer where it was.
struct TranscriptTimeline: View, Equatable {
    let store: TranscriptStore
    /// Built once by the chat's view; its closures hold only references, so a new copy never
    /// changes what the timeline does.
    var actions: TranscriptActions
    @Environment(\.chatColumn) private var column
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var following = Local(true)
    /// Written by the scroll view as the reader scrolls; held without re-rendering. `nudge`
    /// re-renders once, when the position has to be pushed back (after a fold).
    @StateObject private var position = Held(ScrollPosition(edge: .bottom))
    @StateObject private var nudge = Local(0)
    /// A scroll gesture is under way (from its phase): the geometry rules leave following to it.
    @StateObject private var gesturing = Held(false)
    /// The last content height and offset, to undo a fold's shrink above the reader.
    @StateObject private var geometry = Held((height: CGFloat(0), offset: CGFloat(0)))
    @StateObject private var pendingFold = Held(false)
    /// The send already followed, and a saved place still to go back to.
    @StateObject private var lastSend = Held(Date?.none)
    @StateObject private var restore = Held(TranscriptStore.SavedScroll?.none)
    /// After scrolling a saved row to the top: how far into it to go.
    @StateObject private var restoreInRow = Held(CGFloat?.none)
    /// Message rows' tops in the visible area, as they report them, for saving the place.
    @StateObject private var messageTops = Held([String: CGFloat]())
    /// While turns are added above (Load earlier): the message row that was first and its top
    /// on screen. When it reports where it moved, the view follows it by as much, so what's on
    /// screen stays put.
    @StateObject private var anchor = Held((id: String, y: CGFloat)?.none)
    @StateObject private var visibleHeight = Held(CGFloat(0))
    /// The scroll view's top inset (under the title bar): its offset reads -inset at the top,
    /// while `ScrollPosition.scrollTo(y:)` counts from the content's top, so offsets are
    /// converted (`scrollTo(offset:)`).
    @StateObject private var insetTop = Held(CGFloat(0))
    /// Which sections' messages have scrolled past their pinned header.
    @StateObject private var sticky = StickyTracker()

    private static let end = "transcript-end"
    private static let loadRow = "transcript-load-row"
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// This far from the end, a move up without a phase is the reader's, not a pin landing short.
    private static let leftEnd: CGFloat = 150
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2

    var body: some View {
        ScrollViewReader { proxy in
            let rowActions = rowActions(proxy)
            let reveal = reveal(proxy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // One row at the top, never two: earlier turns of this history first, then the
                    // conversation before its compaction.
                    if store.hiddenTurns > 0 {
                        LoadEarlierRow(label: "Load earlier turns") { loadEarlier() }
                    } else if store.earlierAvailable {
                        LoadEarlierRow(
                            label: "Load earlier conversation",
                            loading: store.loadingEarlier ? "Loading earlier conversation…" : nil
                        ) { loadEarlierConversation() }
                            .id(Self.loadRow)
                    }
                    ForEach(store.sections) { section in
                        TimelineSection(section: section, actions: rowActions, reveal: reveal, sticky: sticky)
                            .id(section.id)
                    }
                    Color.clear.frame(height: Stroke.hairline).id(Self.end)
                }
                .padding(.horizontal, column.padding)
                .padding(.top, Layout.Transcript.top)
                .padding(.bottom, Layout.Transcript.bottom)
                .frame(maxWidth: column.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(binding)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                gesturing.value = new != .idle
                if new == .interacting {
                    following.value = false
                    // The reader took over: a place still being restored or kept is dropped.
                    restore.value = nil
                    restoreInRow.value = nil
                    anchor.value = nil
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height, $0.contentInsets.top]
            } action: { _, new in
                insetTop.value = new[3]
                let (height, offset) = (new[0], new[1])
                visibleHeight.value = new[2]
                if let inRow = restoreInRow.value, height > 0 {
                    // The saved row is at the top now: on into it.
                    restoreInRow.value = nil
                    let target = min(offset + inRow, max(0, height - new[2]))
                    scroll(position, to: target)
                    geometry.value = (height, target)
                    nudge.value &+= 1
                    return
                }
                if let saved = restore.value, height > 0 {
                    // Back to where the reader was when this chat's tab was last shown.
                    restore.value = nil
                    if !saved.atEnd {
                        following.value = false
                        if let row = saved.row {
                            proxy.scrollTo(row, anchor: .top)
                            restoreInRow.value = saved.inRow
                        } else {
                            scroll(position, to: min(saved.offset, height))
                            geometry.value = (height, saved.offset)
                            nudge.value &+= 1
                        }
                        return
                    }
                }
                if pendingFold.value, !following.value, height < geometry.value.height {
                    // The fold took height from above the answer: scroll up by as much.
                    pendingFold.value = false
                    let target = max(-insetTop.value, geometry.value.offset - (geometry.value.height - height))
                    scroll(position, to: target)
                    geometry.value = (height, target)
                    nudge.value &+= 1
                    return
                }
                // Moved up, away from the end, with no new content: the scroll bar, Page Up or a
                // programmatic scroll, none of which has a scroll phase. Stop following, or each
                // row measured on the way would pull the view back to the end. Only once there's
                // more than a screen (a shorter chat sits at the bottom and moves as it grows), and
                // only well clear of the end: our own pin aims at estimated row heights and can
                // land a little above it.
                if following.value, height == geometry.value.height, height > new[2] + Self.atBottom,
                    offset < geometry.value.offset - 1, offset + new[2] < height - Self.leftEnd
                {
                    following.value = false
                }
                // And back: moved down to within the slack of the end the same way (the scroll bar,
                // Page Down, End) starts following again, as a phased scroll ending there does,
                // even while a reply streams in. Only between gestures, and only on a move down:
                // content arriving under a reader held just above the end doesn't move them, so
                // it doesn't pull them along.
                if !following.value, !gesturing.value, offset > geometry.value.offset + 1,
                    offset + new[2] >= height - Self.atBottom
                {
                    following.value = true
                }
                // Rows measured after they were placed change the height: while following, stay
                // pinned to the end through layout as well as new content (T3 Code does both).
                if following.value, height != geometry.value.height, store.sentAt.map({ Date().timeIntervalSince($0) >= Self.glide }) ?? true {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                geometry.value = (height, offset)
            }
            .onChange(of: store.folded?.seq) { pendingFold.value = true }
            .onChange(of: store.tail, initial: true) { follow(proxy) }
            .onAppear {
                restore.value = store.savedScroll
                lastSend.value = store.sentAt
                DevSnapshot.earlier { load in
                    // Test hook: go to the top, then load earlier turns.
                    following.value = false
                    position.value.scrollTo(edge: .top)
                    nudge.value &+= 1
                    // Each press takes the top row: earlier turns, then earlier conversation.
                    let env = ProcessInfo.processInfo.environment
                    let times = Int(env["KORE_EARLIER_TIMES"] ?? "") ?? 1
                    if let show = env["KORE_EARLIER_SHOW"] {
                        // Then show the first divider, or the top.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + 2 * Double(load ? times : 0)) {
                            let divider = store.sections.lazy.flatMap(\.items).first {
                                if case .entry(let e) = $0.row { return e.kind == .divider }
                                return false
                            }
                            if show == "divider", let divider {
                                proxy.scrollTo(divider.id, anchor: .center)
                            } else {
                                proxy.scrollTo(Self.loadRow, anchor: .top)
                            }
                        }
                    }
                    for press in 0..<(load ? times : 0) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 2 * Double(press)) {
                            if store.hiddenTurns > 0 {
                                loadEarlier()
                            } else if store.earlierAvailable {
                                loadEarlierConversation()
                            }
                        }
                    }
                }
            }
            .onDisappear {
                // The last message row at or above the top, and how far the top is into it.
                let above = messageTops.value.filter { $0.value <= 0.5 }.max { $0.value < $1.value }
                store.savedScroll = TranscriptStore.SavedScroll(
                    row: above?.key, inRow: -(above?.value ?? 0), offset: geometry.value.offset, atEnd: following.value)
            }
        }
    }

    /// Pins the end while following: at once, or gliding for 2s after a send. A send always
    /// brings the end back into view.
    private func follow(_ proxy: ScrollViewProxy) {
        if let sent = store.sentAt, sent != lastSend.value {
            lastSend.value = sent
            following.value = true
        }
        guard following.value else { return }
        let gliding = !reduceMotion && store.sentAt.map { Date().timeIntervalSince($0) < Self.glide } == true
        if gliding {
            withAnimation(Motion.glide) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// Scrolls so the scroll view's offset (as its geometry reports it) becomes `offset`.
    private func scroll(_ position: Held<ScrollPosition>, to offset: CGFloat) {
        position.value.scrollTo(y: offset + insetTop.value)
    }

    /// Twenty more turns above; what's on screen stays where it was (`anchor`).
    private func loadEarlier() {
        keepFirstMessage()
        store.loadEarlier()
    }

    /// The conversation before a compaction; it arrives later (read from disk), and what's on
    /// screen then stays where it was.
    private func loadEarlierConversation() {
        keepFirstMessage()
        actions.loadEarlierConversation()
    }

    private func keepFirstMessage() {
        following.value = false
        guard let id = store.sections.first?.header?.id.uuidString, let y = messageTops.value[id] else { return }
        anchor.value = (id, y)
    }

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        return Binding(get: { position.value }, set: { position.value = $0 })
    }

    /// Rows' actions: scrolling back to a message, and reporting where messages are.
    private func rowActions(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = reveal(proxy)
        let sticky = sticky
        let tops = messageTops
        let (anchor, geometry, position, nudge) = (anchor, geometry, position, nudge)
        let scroll = scroll
        actions.messageMoved = { id, y in
            sticky.row(id, y)
            tops.value[id] = y
            if let kept = anchor.value, kept.id == id, abs(y - kept.y) > 0.5 {
                // Turns arrived above it: follow it down by as far as it moved.
                anchor.value = nil
                let target = geometry.value.offset + (y - kept.y)
                scroll(position, target)
                geometry.value.offset = target
                nudge.value &+= 1
            }
        }
        return actions
    }

    private func reveal(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = actions
        actions.reveal = { id in
            following.value = false
            withAnimation(Motion.fade) { proxy.scrollTo(id, anchor: .top) }
        }
        return actions
    }
}

extension TranscriptTimeline {
    /// One timeline per store: a chat view drawn again with new action closures doesn't draw it
    /// again.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.store === b.store }
}

/// One section, reading only its own model: a streamed token re-renders the section it lands
/// in, not the transcript.
private struct TimelineSection: View {
    let section: TranscriptStore.SectionModel
    let actions: TranscriptActions
    let reveal: TranscriptActions
    let sticky: StickyTracker

    var body: some View {
        Section {
            ForEach(section.items) { item in
                TimelineRow(item: item, actions: actions).equatable()
            }
        } header: {
            if let header = section.header {
                StickyMessage(entry: header, open: section.headerOpen, actions: reveal, tracker: sticky).equatable()
            }
        }
    }
}
