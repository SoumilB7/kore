import KoreCore
import SwiftUI

/// The conversation as a timeline (look.md §2). Sections start at each user message, whose box
/// sticks to the top while its section scrolls by. Rows are built lazily and compare by value,
/// and only the last turns are built: scrolling up near the top adds more above, keeping the view
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
    @Environment(\.hiddenTab) private var hidden
    /// The sections and the end as they were when the chat's tab hid.
    @StateObject private var frozen = Frozen<(sections: [TranscriptStore.SectionModel], tail: Int)>()
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
    /// Until then, a glide to the end is under way: layout doesn't pin over it. And the send
    /// whose glide a tab switch cut: the rest of its reply is pinned at once.
    @StateObject private var glidingUntil = Held(Date?.none)
    @StateObject private var glideCut = Held(Date?.none)
    @StateObject private var restore = Held(TranscriptStore.SavedScroll?.none)
    /// After scrolling a saved row to the top: how far into it to go.
    @StateObject private var restoreInRow = Held(CGFloat?.none)
    /// Built message and answer rows' tops from the top of the visible area (below the title
    /// bar), as they report them, for saving the place.
    @StateObject private var rowTops = Held([String: CGFloat]())
    /// The built answers' tops among them. Not messages: a message sticks to the top, so where
    /// it is on screen isn't where it is in the content.
    @StateObject private var answerTops = Held([String: CGFloat]())
    /// The content's height just before turns went in above: the view moves down by what they
    /// added, at once (`ScrollShift`).
    @StateObject private var paged = Held(CGFloat?.none)
    /// And the first answer on screen then, with its top. The turns that went in are only
    /// estimated, so that move can be off: once it's `placed`, the answer's next report (it's
    /// back on screen) moves the view by what's left. When none comes by the next scroll update
    /// (the estimate was off by more than a screen, so the answer isn't built), the view is
    /// taken to the answer (`sought`), and its report then puts it back; one that doesn't come
    /// within half a second lets it go.
    @StateObject private var anchor = Held((id: String, top: CGFloat, placed: Bool, waited: Bool, sought: Date?)?.none)
    /// How far the reader scrolled while the answer was kept, so putting it back doesn't undo
    /// that; `skip`: the next move is the one taking the view to the answer.
    @StateObject private var readerMoved = Held((by: CGFloat(0), skip: false))
    /// The earlier conversation was asked for by scrolling up here, and hasn't come yet.
    @StateObject private var fetching = Held(false)
    @StateObject private var shift = ScrollShift()
    @StateObject private var visibleHeight = Held(CGFloat(0))
    /// The scroll view's top inset (under the title bar): its offset reads -inset at the top,
    /// while `ScrollPosition.scrollTo(y:)` counts from the content's top, so offsets are
    /// converted (`scrollTo(offset:)`).
    @StateObject private var insetTop = Held(CGFloat(0))
    /// Which sections' messages have scrolled past their pinned header.
    @StateObject private var sticky = StickyTracker()
    /// The scroll view's last geometry: content height, offset, visible height, top inset.
    @StateObject private var seen = Held([CGFloat]())
    /// A shown transcript with rows and none of them on screen (`checkBlank`): the check under
    /// way, and how often the scroll view was built again for it.
    @StateObject private var blankCheck = Held(Task<Void, Never>?.none)
    @StateObject private var remounts = Held(0)
    @StateObject private var mount = Local(0)

    private static let end = "transcript-end"
    private static let loadRow = "transcript-load-row"
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// This far from the end, a move up without a phase is the reader's, not a pin landing short.
    private static let leftEnd: CGFloat = 150
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2

    var body: some View {
        let (sections, tail) = frozen(hidden) { (store.sections, store.tail) }
        return ScrollViewReader { proxy in
            let rowActions = rowActions(proxy)
            let reveal = reveal(proxy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // One row at the top, never two: earlier turns of this history first, then the
                    // conversation before its compaction.
                    if store.hiddenTurns > 0 {
                        LoadEarlierRow(label: "Load earlier turns") { loadEarlier() }
                            .storyID(StoryID.Transcript.earlier)
                    } else if store.earlierAvailable {
                        LoadEarlierRow(
                            label: "Load earlier conversation",
                            loading: store.loadingEarlier ? "Loading earlier conversation…" : nil
                        ) { loadEarlierConversation() }
                            .storyID(StoryID.Transcript.earlier)
                            .id(Self.loadRow)
                    }
                    ForEach(sections) { section in
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
                // One text selection over every row: rows report their texts in this space, and
                // the responder at its corner follows the pointer in it.
                .background(alignment: .topLeading) {
                    SelectionResponder(selection: store.selection, hidden: hidden, openLink: actions.openLink)
                        .frame(width: Stroke.hairline, height: Stroke.hairline)
                    ScrollShift.Finder(shift).frame(width: Stroke.hairline, height: Stroke.hairline)
                }
                .coordinateSpace(.named(TranscriptSelection.space))
                .environment(\.transcriptSelection, store.selection)
                // Links outside the selection's texts (a tool's file) open as its own do.
                .environment(\.openURL, OpenURLAction { [selection = store.selection] url in
                    selection.open(url)
                    return .handled
                })
            }
            // Built again when a shown transcript draws none of its rows (`checkBlank`).
            .id(mount.value)
            .accessibilityAction(named: Text("Copy Selection")) { store.selection.copy() }
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
                    paged.value = nil
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height, $0.contentInsets.top]
            } action: { _, new in
                seen.value = new
                insetTop.value = new[3]
                let (height, offset) = (new[0], new[1])
                visibleHeight.value = new[2]
                // Under another tab, nobody reads or scrolls it: its moves are layout's and a glide's
                // still under way, and say nothing of where the reader is. It shows as it was left.
                if hidden {
                    geometry.value = (height, offset)
                    return
                }
                if let inRow = restoreInRow.value, height > 0 {
                    // The saved row's top is at the top of the visible area now: on into it (or
                    // back above it).
                    restoreInRow.value = nil
                    let target = min(max(offset + inRow, -insetTop.value), max(0, height - new[2]))
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
                            // Never past the end: the content can be shorter than when it was left.
                            let target = min(saved.offset, max(0, height - new[2]))
                            scroll(position, to: target)
                            geometry.value = (height, target)
                            nudge.value &+= 1
                        }
                        return
                    }
                }
                if anchor.value != nil {
                    if readerMoved.value.skip {
                        readerMoved.value.skip = false
                    } else {
                        readerMoved.value.by += offset - geometry.value.offset
                    }
                }
                if let before = paged.value, height > before {
                    // Turns went in above: down by what they added, so what's on screen stays put.
                    paged.value = nil
                    anchor.value?.placed = true
                    let target = offset + (height - before)
                    if !shift(height - before) {
                        scroll(position, to: target)
                        nudge.value &+= 1
                    }
                    geometry.value = (height, target)
                    return
                }
                if let kept = anchor.value, kept.placed {
                    if !kept.waited {
                        anchor.value?.waited = true
                    } else if let sought = kept.sought {
                        if Date().timeIntervalSince(sought) > 0.5 { anchor.value = nil }
                    } else {
                        anchor.value?.sought = Date()
                        readerMoved.value.skip = true
                        proxy.scrollTo(kept.id, anchor: .top)
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
                if following.value, height != geometry.value.height, glidingUntil.value.map({ Date() >= $0 }) ?? true {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                // Within a screen of the top on the way up: earlier turns go in above, as the top
                // row's press does, with what's on screen kept where it is. Only the reader's own
                // scroll: never a place being restored (a tab coming back).
                if !following.value, restore.value == nil, restoreInRow.value == nil, anchor.value == nil, paged.value == nil,
                    !fetching.value, offset < geometry.value.offset - 1, offset + insetTop.value < new[2]
                {
                    if store.hiddenTurns > 0 {
                        loadEarlier()
                    } else if store.earlierAvailable, !store.loadingEarlier {
                        loadEarlierConversation()
                    }
                }
                geometry.value = (height, offset)
            }
            .onChange(of: store.folded?.seq) { pendingFold.value = true }
            .onChange(of: store.loadingEarlier) { _, loading in
                // The earlier conversation is in (and laid out next): what's on screen stays.
                if !loading, fetching.value {
                    fetching.value = false
                    paged.value = geometry.value.height
                }
            }
            // New content follows the end; a tab showing again is at its end at once if it was
            // following when it hid, whatever came meanwhile. Nothing moves while it's hidden, and
            // a tab showing with nothing new and no glide cut short stays as it was left.
            .onChange(of: [tail, hidden ? 1 : 0], initial: true) { old, new in
                checkBlank(hidden: new[1] == 1)
                guard new[1] == 0 else { return }
                let showing = old[1] == 1
                if showing, old[0] == new[0], glidingUntil.value.map({ Date() >= $0 }) ?? true { return }
                follow(proxy, showing: showing)
            }
            .onAppear {
                if StoryHost.installed {
                    store.storyScroll = { id in
                        following.value = false
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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
                // The row nearest the top of the visible area, and how far below its top that is
                // (negative: above it). It comes back exactly, however the rows above it measure
                // when they're built again.
                let place = rowTops.value.min { abs($0.value) < abs($1.value) }.map { (key: $0.key, value: -$0.value) }
                store.savedScroll = TranscriptStore.SavedScroll(
                    row: place?.key, inRow: place?.value ?? 0, offset: geometry.value.offset, atEnd: following.value)
            }
        }
    }

    /// Two seconds after it shows or changes, a transcript with rows but none on screen (none
    /// built, all below the visible area, or scrolled past its end) is logged with its geometry
    /// in sessions.log ("blank"), and its scroll view is built again at the end, once.
    private func checkBlank(hidden: Bool) {
        blankCheck.value?.cancel()
        guard !hidden else { return }
        let (store, seen, tops, remounts, mount, position, following) = (store, seen, rowTops, remounts, mount, position, following)
        blankCheck.value = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !store.sections.isEmpty, seen.value.count == 4 else { return }
            let (height, offset, visible) = (seen.value[0], seen.value[1], seen.value[2])
            // Only where the end should show (opened, following) or past it: a reader up among
            // a turn's tool rows has no message or answer on screen, and stays where they are.
            let onScreen = tops.value.values.contains { $0 < visible }
            guard (!onScreen && following.value) || offset > height else {
                if remounts.value > 0 {
                    KoreLog.named("sessions").write("blank-recovered", ["cli": store.providerName])
                    remounts.value = 0
                }
                return
            }
            KoreLog.named("sessions").write(
                "blank",
                [
                    "cli": store.providerName, "sections": String(store.sections.count), "rows": String(store.entries.count),
                    "height": String(Int(height)), "offset": String(Int(offset)), "visible": String(Int(visible)),
                    "tops": String(tops.value.count), "first_top": tops.value.values.min().map { String(Int($0)) },
                    "following": following.value ? "yes" : "no", "remounts": String(remounts.value),
                ])
            guard remounts.value < 1 else { return }
            remounts.value += 1
            following.value = true
            position.value = ScrollPosition(edge: .bottom)
            mount.value &+= 1
        }
    }

    /// Pins the end while following: at once, or gliding for 2s after a send. A send always
    /// brings the end back into view. A tab `showing` again never glides: it's there at once.
    private func follow(_ proxy: ScrollViewProxy, showing: Bool = false) {
        if let sent = store.sentAt, sent != lastSend.value {
            lastSend.value = sent
            following.value = true
        }
        guard following.value else { return }
        let glideEnd = store.sentAt.map { $0.addingTimeInterval(Self.glide) }
        if !showing, !reduceMotion, store.sentAt != glideCut.value, let glideEnd, Date() < glideEnd {
            glidingUntil.value = glideEnd
            withAnimation(Motion.glide) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else if showing {
            // Over any glide it hid in the middle of.
            glidingUntil.value = nil
            glideCut.value = store.sentAt
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
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
        keepPlace()
        paged.value = geometry.value.height
        store.loadEarlier()
    }

    /// The conversation before a compaction; it arrives later (read from disk), and what's on
    /// screen then stays where it was.
    private func loadEarlierConversation() {
        keepPlace()
        fetching.value = true
        actions.loadEarlierConversation()
    }

    private func keepPlace() {
        following.value = false
        anchor.value = answerTops.value.filter { $0.value >= 0 }.min { $0.value < $1.value }.map { ($0.key, $0.value, false, false, nil) }
        readerMoved.value = (0, false)
    }

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        return Binding(get: { position.value }, set: { position.value = $0 })
    }

    /// Rows' actions: scrolling back to a message, and reporting where messages are.
    private func rowActions(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = reveal(proxy)
        let sticky = sticky
        let (tops, answerTops) = (rowTops, answerTops)
        let (anchor, readerMoved, geometry, position, nudge, shift, visible) = (anchor, readerMoved, geometry, position, nudge, shift, visibleHeight)
        let scroll = scroll
        actions.messageMoved = { id, frame in
            guard let frame else {
                tops.value[id] = nil
                return
            }
            sticky.row(id, frame.maxY)
            tops.value[id] = frame.minY
        }
        actions.answerMoved = { id, top in
            tops.value[id] = top
            answerTops.value[id] = top
            // Back on screen after turns went in above: on by what the move missed.
            guard let top, let kept = anchor.value, kept.id == id, kept.placed, abs(top) < visible.value else { return }
            anchor.value = nil
            let dy = top - (kept.top - readerMoved.value.by)
            geometry.value.offset += dy
            if abs(dy) > 0.5, !shift(dy) {
                scroll(position, geometry.value.offset)
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
    @Environment(\.hiddenTab) private var hidden
    /// Its rows as they were when the chat's tab hid.
    @StateObject private var frozen = Frozen<(items: [TranscriptStore.Item], header: TranscriptStore.Entry?, open: Bool)>()

    var body: some View {
        let (items, header, open) = frozen(hidden) { (section.items, section.header, section.headerOpen) }
        return Section {
            ForEach(items) { item in
                TimelineRow(item: item, actions: actions).equatable()
            }
        } header: {
            if let header {
                StickyMessage(entry: header, open: open, actions: reveal, tracker: sticky).equatable()
            }
        }
    }
}
