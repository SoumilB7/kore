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

    private static let end = "transcript-end"
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if store.hiddenTurns > 0 {
                        LoadEarlierRow { loadEarlier(proxy) }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { loadRow.value = $0 }
                    }
                    ForEach(store.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                TimelineRow(item: item, actions: actions).equatable()
                            }
                        } header: {
                            if let header = section.header {
                                MessageHeader(entry: header, open: section.headerOpen, actions: reveal(proxy))
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
            .scrollPosition(binding)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                if new == .interacting {
                    following.value = false
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
            .onChange(of: store.tail, initial: true) { follow(proxy) }
            .onAppear {
                restore.value = store.savedScroll
                lastSend.value = store.sentAt
                DevSnapshot.earlier { load in
                    // Test hook: go to the top, then load earlier turns.
                    following.value = false
                    position.value.scrollTo(edge: .top)
                    nudge.value &+= 1
                    if load { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { loadEarlier(proxy) } }
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

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        return Binding(get: { position.value }, set: { position.value = $0 })
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
