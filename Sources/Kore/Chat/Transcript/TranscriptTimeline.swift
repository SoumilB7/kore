import SwiftUI

/// The conversation as a timeline (look.md §2). Sections start at each user message, whose box
/// sticks to the top while its section scrolls by. Rows are built lazily and compare by value,
/// and only the last turns are built: "Load earlier turns" adds more above, keeping the view
/// still. Following the end works as in the Claude Code extension (live-streaming.md): within
/// 50pt of the bottom new content is pinned at once, for 2s after a send it glides, and once the
/// reader scrolls up nothing moves. A turn folding above the answer keeps the answer where it was.
struct TranscriptTimeline: View {
    let store: TranscriptStore
    var actions: TranscriptActions
    @Environment(\.chatColumn) private var column
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var following = Local(true)
    /// Written by the scroll view as the reader scrolls; held without re-rendering. `nudge`
    /// re-renders once, when the position has to be pushed back (after a fold).
    @StateObject private var position = Held(ScrollPosition(edge: .bottom))
    @StateObject private var nudge = Local(0)
    /// The last content height and offset, to undo a fold's shrink above the reader.
    @StateObject private var geometry = Held((height: CGFloat(0), offset: CGFloat(0)))
    @StateObject private var pendingFold = Held(false)
    /// The send already followed, and a saved place still to go back to.
    @StateObject private var lastSend = Held(Date?.none)
    @StateObject private var restore = Held((offset: CGFloat, atEnd: Bool)?.none)
    /// The "Load earlier turns" row's frame in the visible area, and the visible height: where
    /// the section under it sits, so it stays there once earlier turns are added above.
    @StateObject private var loadRow = Held(CGRect.zero)
    @StateObject private var visibleHeight = Held(CGFloat(0))
    /// Which sections' messages have scrolled past their pinned header.
    @StateObject private var sticky = StickyTracker()

    private static let end = "transcript-end"
    private static let loadRow = "transcript-load-row"
    /// The timeline's own coordinate space: where the message menu is placed.
    nonisolated static let space = "transcript"
    /// A user message's open action menu, and its button's frame.
    @StateObject private var menu = Local<(entry: TranscriptStore.Entry, frame: CGRect)?>(nil)
    /// After earlier conversation is added: the section to keep where it was, and where.
    @StateObject private var pendingAnchor = Held((id: String, point: UnitPoint)?.none)
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // One row at the top, never two: earlier turns of this history first, then the
                    // conversation before its compaction.
                    if store.hiddenTurns > 0 {
                        LoadEarlierRow(label: "Load earlier turns") { loadEarlier(proxy) }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { loadRow.value = $0 }
                    } else if store.earlierAvailable {
                        LoadEarlierRow(
                            label: "Load earlier conversation",
                            loading: store.loadingEarlier ? "Loading earlier conversation…" : nil
                        ) { loadEarlierConversation() }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { loadRow.value = $0 }
                            .id(Self.loadRow)
                    }
                    ForEach(store.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                TimelineRow(item: item, actions: rowActions(proxy)).equatable()
                            }
                        } header: {
                            if let header = section.header {
                                StickyMessage(
                                    entry: header, open: section.headerOpen, actions: reveal(proxy), tracker: sticky)
                            }
                        }
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
            .overlay(alignment: .topLeading) { messageMenu }
            .environment(\.messageMenuOpen, menu.value?.entry.id)
            .coordinateSpace(.named(Self.space))
            .scrollPosition(binding)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                if new == .interacting {
                    following.value = false
                    menu.value = nil
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height]
            } action: { _, new in
                let (height, offset) = (new[0], new[1])
                visibleHeight.value = new[2]
                if let saved = restore.value, height > 0 {
                    // Back to where the reader was when this chat's tab was last shown.
                    restore.value = nil
                    if !saved.atEnd {
                        following.value = false
                        position.value.scrollTo(y: min(saved.offset, height))
                        geometry.value = (height, saved.offset)
                        nudge.value &+= 1
                        return
                    }
                }
                if pendingFold.value, !following.value, height < geometry.value.height {
                    // The fold took height from above the answer: scroll up by as much.
                    pendingFold.value = false
                    let target = max(0, geometry.value.offset - (geometry.value.height - height))
                    position.value.scrollTo(y: target)
                    geometry.value = (height, target)
                    nudge.value &+= 1
                    return
                }
                // Rows measured after they were placed change the height: while following, stay
                // pinned to the end through layout as well as new content (T3 Code does both).
                if following.value, height != geometry.value.height, store.sentAt.map({ Date().timeIntervalSince($0) >= Self.glide }) ?? true {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                geometry.value = (height, offset)
            }
            .onChange(of: store.folded?.seq) { pendingFold.value = true }
            .onChange(of: store.tail, initial: true) {
                if let anchor = pendingAnchor.value {
                    // Earlier conversation arrived above: keep the old first section in place.
                    pendingAnchor.value = nil
                    DispatchQueue.main.async { proxy.scrollTo(anchor.id, anchor: anchor.point) }
                    return
                }
                follow(proxy)
            }
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
                                loadEarlier(proxy)
                            } else if store.earlierAvailable {
                                loadEarlierConversation()
                            }
                        }
                    }
                }
            }
            .onDisappear {
                store.savedScroll = (geometry.value.offset, following.value)
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

    /// Twenty more turns above; the section that was first stays exactly where it was on screen
    /// (just under the row that was clicked).
    private func loadEarlier(_ proxy: ScrollViewProxy) {
        following.value = false
        let anchor = store.sections.first?.id
        let top = loadRow.value.maxY
        let height = visibleHeight.value
        store.loadEarlier()
        guard let anchor else { return }
        let point = UnitPoint(x: 0, y: height > 0 ? min(max(top / height, 0), 1) : 0)
        DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: point) }
    }

    /// The conversation before a compaction; it arrives later (read from disk), and the section
    /// that was first then stays where it was.
    private func loadEarlierConversation() {
        following.value = false
        if let anchor = store.sections.first?.id {
            let height = visibleHeight.value
            pendingAnchor.value = (anchor, UnitPoint(x: 0, y: height > 0 ? min(max(loadRow.value.maxY / height, 0), 1) : 0))
        }
        actions.loadEarlierConversation()
    }

    /// A message's action menu, under its button (above it near the bottom), over the rows.
    @ViewBuilder private var messageMenu: some View {
        if let open = menu.value {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { menu.value = nil }
                let below = open.frame.maxY + Space.menuGap
                let y = below + Size.forkMenuRow > visibleHeight.value && visibleHeight.value > 0
                    ? open.frame.minY - Space.menuGap - Size.forkMenuRow : below
                MessageMenu {
                    menu.value = nil
                    actions.fork(open.entry)
                }
                .offset(x: max(0, open.frame.maxX - Size.forkMenu), y: y)
                .transition(.opacity)
            }
            .animation(Motion.menuFade, value: open.entry.id)
        }
    }

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        return Binding(get: { position.value }, set: { position.value = $0 })
    }

    /// Rows' actions: scrolling back to a message, and reporting where messages are.
    private func rowActions(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = reveal(proxy)
        let sticky = sticky
        actions.messageMoved = { id, y in sticky.row(id, y) }
        let menu = menu
        actions.messageMenu = { entry, frame in menu.value = (entry, frame) }
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
