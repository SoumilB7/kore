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
    /// A board tile: the pinned message is a band the transcript is inset under.
    @Environment(\.pinnedBand) private var band
    /// The sections as they were when the chat's tab hid. The end (`store.tail`, a change per
    /// streamed token) is read by `TailWatch` alone, so a token doesn't draw the timeline again.
    @StateObject private var frozen = Frozen<[TranscriptStore.SectionModel]>()
    @StateObject private var following = Local(true)
    /// Long messages open, and whether the end was followed when the first opened: followed
    /// again once they've all closed.
    @StateObject private var openMessages = Held((count: 0, followed: false))
    @StateObject private var zoomFollowing = Held(Bool?.none)
    @StateObject private var zoomRejoining = Held(false)
    /// The native clip origin a pinch began at: a release away from it is a pinch that moved the view.
    @StateObject private var zoomBegan = Held(CGPoint.zero)
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
    /// The reader's place kept as the width changes.
    @StateObject private var widthHold = WidthHold()
    /// The built answers' tops among them. Not messages: a message sticks to the top, so where
    /// it is on screen isn't where it is in the content.
    @StateObject private var answerTops = Held([String: CGFloat]())
    /// The content's height just before turns went in above: the view moves down by what they
    /// added, at once (`ScrollShift`).
    @StateObject private var paged = Held(CGFloat?.none)
    /// A jump is landing: its own moves aren't the reader nearing the top.
    @StateObject private var landingUntil = Held(Date.distantPast)
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
    /// The top inset changed while following and the end isn't reached again yet: AppKit moves
    /// the clip for a new inset (to the top, when the window first shows), which is layout's
    /// move, not the reader's.
    @StateObject private var insetSettling = Held(false)
    /// Which sections' messages have scrolled past their pinned header.
    @StateObject private var sticky = StickyTracker()
    /// Held, not observed: only the scroller redraws when it changes, never this view.
    @StateObject private var reading = Held(MessageReading())
    /// The rows' actions, built once (their closures hold only references), so a section drawn
    /// again with the same model is skipped.
    @StateObject private var built = Held((rows: TranscriptActions, reveal: TranscriptActions)?.none)
    /// The scroll view's last geometry: content height, offset, visible height, top inset, width.
    @StateObject private var seen = Held([CGFloat]())
    /// That, as it last was on screen: under another tab a new height of the composer's (a new
    /// chat's import line) moves it, and that says nothing of where the reader left it.
    @StateObject private var seenShown = Held([CGFloat]())
    /// Built anew out of sight (`renewOutOfSight`), and laying out until then.
    @StateObject private var renewing = Held(Date?.none)
    /// A shown transcript with rows and none of them on screen (`checkBlank`): the check under
    /// way and when it looks (each call moves that on), how often the scroll view was built again
    /// for it, and when it was lately (a few a minute at most).
    @StateObject private var blankCheck = Held((task: Task<Void, Never>?.none, due: Date.distantPast, soon: false))
    @StateObject private var remounts = Held(0)
    @StateObject private var remountedAt = Held([Date]())
    /// A view new or built again, until its layout settles (each change of height puts that off,
    /// up to `limit`): the offset it's held at, or none to only keep it within the measured end.
    @StateObject private var settling = Held((offset: CGFloat?, until: Date, limit: Date)?.none)
    @StateObject private var mount = Local(0)
    @StateObject private var shown = Held(false)
    /// The store this view counts as on screen in (`countOnScreen`).
    @StateObject private var counted = Held(TranscriptStore?.none)

    private static let end = "transcript-end"
    private static let loadRow = "transcript-load-row"
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// This far from the end, a move up without a phase is the reader's, not a pin landing short.
    private static let leftEnd: CGFloat = 150
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2
    private static let landing: TimeInterval = 0.5
    /// A scroll view new or built again has laid out this long after its height last changed,
    /// and within `settleLimit` in all.
    private static let settle: TimeInterval = 0.5
    private static let settleLimit: TimeInterval = 1.5

    var body: some View {
        // What left memory leaves here too, behind another tab: all this view holds is let go.
        let sections = frozen(hidden, epoch: store.unloads) { store.sections }
        return ScrollViewReader { proxy in
            let (rowActions, reveal) = builtActions(proxy)
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
                    // The bottom padding is the end's own: pinning the end (`scrollTo`) and the
                    // scroll position's bottom edge land on the same place, not a padding apart,
                    // so the two never pull the view between them.
                    Color.clear.frame(height: Layout.Transcript.bottom).id(Self.end)
                }
                .padding(.horizontal, column.padding)
                .padding(.top, Layout.Transcript.top)
                .frame(maxWidth: column.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                // One text selection over every row: rows report their texts in this space, and
                // the responder at its corner follows the pointer in it.
                .background(alignment: .topLeading) {
                    SelectionResponder(selection: store.selection, hidden: hidden, openLink: actions.openLink, folder: actions.folder)
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
            .overlay(alignment: .trailing) {
                if !hidden, !band {
                    MessageRail(store: store, tracker: sticky, reading: reading.value, atEnd: following.value, actions: actions) { id in
                        // The reader's new place: nothing held from before pulls it back.
                        following.value = false
                        letGo()
                        anchor.value = nil
                        paged.value = nil
                        restore.value = nil
                        restoreInRow.value = nil
                        landingUntil.value = Date().addingTimeInterval(Self.landing)
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
            // Away from the end, a line under the bottom edge fades out rather than being cut.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: Size.tabFade)
                    .opacity(following.value ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // A board tile's pinned message takes its height: the transcript is inset under it.
            // Elsewhere there's no inset at all, so the lazy stack's estimates don't measure up
            // through one.
            .modifier(BandInset(band: band, sections: sections, reveal: reveal, tracker: sticky))
            .accessibilityAction(named: Text("Copy Selection")) { store.selection.copy() }
            .scrollPosition(binding)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                gesturing.value = new != .idle
                // The end the view was taken to can lie below the rows: the check looks when it stops.
                if new == .idle { checkBlank() }
                guard !shift.zoomAdjusting else { return }
                if new == .interacting {
                    zoomRejoining.value = false
                    following.value = false
                    letGo()
                    // The reader took over: a place still being restored or kept is dropped.
                    restore.value = nil
                    settling.value = nil
                    restoreInRow.value = nil
                    anchor.value = nil
                    paged.value = nil
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height, $0.contentInsets.top, $0.containerSize.width]
            } action: { old, new in
                seen.value = new
                // Where the reader left it (`WidthHold`): at an unchanged width, and not while a
                // new one is still being laid out (held).
                if !shift.keep(), !widthHold.holding, old.count == new.count, new[4] == old[4] {
                    // The content's height is partly estimated: at its end only with no built row
                    // reaching past the bottom of the view.
                    widthHold.rest = (new[1], new[1] + new[2] >= new[0] - Self.atBottom && widthHold.rowsEnd(above: new[1] + new[3] + new[2] + Self.atBottom))
                }
                let insetMoved = new[3] != insetTop.value
                insetTop.value = new[3]
                let (height, offset) = (new[0], new[1])
                // A card arriving or growing under it takes height from the bottom: the end
                // would slide under the card.
                let visibleMoved = new[2] != visibleHeight.value
                visibleHeight.value = new[2]
                // Built anew out of sight: at the end through its layout, shown by now or not. Those
                // moves aren't the reader's, who takes over by scrolling (nothing followed then).
                var renewed = false
                if let until = renewing.value {
                    if Date() >= until {
                        renewing.value = nil
                    } else if following.value {
                        renewed = true
                        if abs(offset + new[2] - height) > 1 {
                            var instant = Transaction()
                            instant.disablesAnimations = true
                            withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                    }
                }
                // Under another tab, nobody reads or scrolls it: its moves are layout's and a glide's
                // still under way, and say nothing of where the reader is. It shows as it was left.
                if hidden {
                    geometry.value = (height, offset)
                    return
                }
                seenShown.value = new
                // A move with no scroll phase (the scroll bar, End) never reaches `.idle` above.
                // A new width can leave the content's height past its rows: looked at soon.
                if old.count == new.count, old[4] > 0, new[4] != old[4] { checkBlank(soon: true) }
                if !gesturing.value, offset != geometry.value.offset { checkBlank() }
                // Keep measuring, but let neither a retained bottom target nor restoration,
                // paging or folding replace the absolute position held during a pinch.
                if shift.zoomAdjusting {
                    geometry.value = (height, offset)
                    return
                }
                // A new top inset moves the clip (`insetSettling`): pinned again below.
                if insetMoved, following.value { insetSettling.value = true }
                // A new width wraps the rows anew: at the end, the view stays there through every
                // pass of it (`WidthHold` keeps a reader's place above it), and a glide stops.
                if following.value, old.count == new.count, old[4] > 0, new[4] != old[4] {
                    if widthHold.rest?.atEnd ?? true {
                        glidingUntil.value = nil
                        glideCut.value = store.sentAt
                        shift.hold(.end, until: Date() + WidthHold.lasts)
                    } else {
                        // Left above the end by a move with no scroll phase: not followed.
                        following.value = false
                    }
                }
                // Held through a new width: nothing else moves the view meanwhile. A kept row
                // laid out off screen is sought again until it's built.
                let widthHeld = shift.keep() || widthHold.holding
                if let id = widthHold.seeking, widthHold.holding {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { proxy.scrollTo(id, anchor: .top) }
                }
                // Native reset geometry may arrive after the ending layout pass. It is not
                // a reader scrolling away: wait for the explicit bottom target to land.
                if zoomRejoining.value {
                    geometry.value = (height, offset)
                    if offset + new[2] >= height - Self.atBottom { zoomRejoining.value = false }
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
                        settle(at: nil)
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
                if let place = settling.value, height > 0 {
                    // A view new or built again lays out, takes its inset and its default anchor,
                    // and measures the rows it only estimated, over a few passes: meanwhile it's
                    // never past the measured end (where nothing draws), and a rebuilt one is held
                    // where the reader was, with nothing following.
                    let now = Date()
                    if height != geometry.value.height { settling.value?.until = min(now + Self.settle, place.limit) }
                    if let until = settling.value?.until, now < until {
                        let target = min(max(place.offset ?? offset, -insetTop.value), max(0, height - new[2]))
                        if abs(offset - target) > 0.5 {
                            scroll(position, to: target)
                            nudge.value &+= 1
                            geometry.value = (height, target)
                            return
                        }
                        if place.offset != nil {
                            geometry.value = (height, target)
                            return
                        }
                    } else {
                        settling.value = nil
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
                if insetSettling.value, !following.value || gesturing.value || offset + new[2] >= height - Self.atBottom {
                    insetSettling.value = false
                }
                if !shift.zoomAdjusting, following.value, !widthHeld, !renewed, !insetSettling.value, height == geometry.value.height, height > new[2] + Self.atBottom,
                    offset < geometry.value.offset - 1, offset + new[2] < height - Self.leftEnd
                {
                    following.value = false
                }
                // And back: moved down to within the slack of the end the same way (the scroll bar,
                // Page Down, End) starts following again, as a phased scroll ending there does,
                // even while a reply streams in. Only between gestures, and only on a move down:
                // content arriving under a reader held just above the end doesn't move them, so
                // it doesn't pull them along.
                if !shift.zoomAdjusting, !following.value, !widthHeld, !gesturing.value, offset > geometry.value.offset + 1,
                    offset + new[2] >= height - Self.atBottom
                {
                    following.value = true
                }
                // Rows measured after they were placed change the height: while following, stay
                // pinned to the end through layout (an inset's move, the visible height's too) as
                // well as new content (T3 Code does both).
                if !shift.zoomAdjusting, following.value, !widthHeld, height != geometry.value.height || insetSettling.value || visibleMoved,
                    glidingUntil.value.map({ Date() >= $0 }) ?? true
                {
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                // Within a screen of the top on the way up: earlier turns go in above, as the top
                // row's press does, with what's on screen kept where it is. Only the reader's own
                // scroll: never a place being restored (a tab coming back).
                if !following.value, restore.value == nil, restoreInRow.value == nil, anchor.value == nil, paged.value == nil,
                    !fetching.value, !widthHeld, offset < geometry.value.offset - 1, offset + insetTop.value < new[2], Date() >= landingUntil.value
                {
                    if store.hiddenTurns > 0 {
                        loadEarlier()
                    } else if store.earlierAvailable, !store.loadingEarlier {
                        loadEarlierConversation()
                    }
                }
                geometry.value = (height, offset)
            }
            // A history read again brings a store of its own, under this same view.
            .onChange(of: ObjectIdentifier(store), initial: true) {
                // Following it, or there by a move that didn't say so.
                store.readerAtEnd = { [following, gesturing, restore, restoreInRow, shift, seenShown] in
                    let seen = seenShown.value
                    let atEnd = following.value || (seen.count == 5 && seen[1] + seen[2] >= seen[0] - Self.atBottom)
                    return atEnd && !gesturing.value && restore.value == nil && restoreInRow.value == nil && !shift.zoomAdjusting
                }
                // Rows gone while it was out of sight are laid out by now: the end is at once where
                // the end row is, whatever the rows above it were estimated at.
                store.backAtEnd = { [following, glidingUntil, glideCut, weak store = store] in
                    following.value = true
                    glidingUntil.value = nil
                    glideCut.value = store?.sentAt
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                store.readerView = ObjectIdentifier(following)
                countOnScreen()
            }
            // Out of sight behind another tab: the chat's oldest turns can leave memory.
            .onChange(of: hidden) { _, hidden in
                countOnScreen()
                if hidden { actions.unloadOld() }
            }
            .onChange(of: store.unloads) { renewOutOfSight() }
            .onChange(of: store.folded?.seq) {
                pendingFold.value = true
                letGo()
            }
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
            .background {
                TailWatch(store: store, hidden: hidden) { old, new in
                    shown.value = new[1] == 0
                    checkBlank()
                    guard new[1] == 0 else { return }
                    let showing = old[1] == 1
                    if showing, old[0] == new[0], glidingUntil.value.map({ Date() >= $0 }) ?? true { return }
                    follow(proxy, showing: showing)
                }
            }
            .onAppear {
                shift.onZoomBegin = { [glidingUntil, glideCut, store, position, nudge, geometry, insetTop, following, zoomFollowing, zoomRejoining, zoomBegan] native in
                    zoomFollowing.value = following.value
                    zoomBegan.value = native
                    zoomRejoining.value = false
                    glidingUntil.value = nil
                    glideCut.value = store.sentAt
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        // ScrollPosition counts from SwiftUI's content origin. A native
                        // clip origin already includes a different inset conversion.
                        position.value.scrollTo(y: geometry.value.offset + insetTop.value)
                        nudge.value &+= 1
                    }
                }
                shift.onZoomEnd = { [following, zoomFollowing, zoomRejoining, zoomBegan, position, glidingUntil, glideCut, store, shift] resume in
                    guard let previous = zoomFollowing.value else { return }
                    zoomFollowing.value = nil
                    // A pinch that moved the view (zoomed in around the cursor) leaves it where
                    // the last sample put it. The target frozen at begin is dropped, not replaced:
                    // no target, no scroll. Native scrolling owns the place from here, and only
                    // a view still at the end follows.
                    if let frames = shift.frames,
                        hypot(frames.visible.minX - zoomBegan.value.x, frames.visible.minY - zoomBegan.value.y) > 0.5
                    {
                        // SwiftUI's document is flipped: its end is at the bottom.
                        following.value = previous && frames.visible.maxY >= frames.content.maxY - Self.atBottom
                        zoomRejoining.value = false
                        position.value = ScrollPosition()
                        return
                    }
                    following.value = previous
                    guard resume, previous, !hidden else { zoomRejoining.value = false; return }
                    zoomRejoining.value = true
                    glidingUntil.value = nil
                    glideCut.value = store.sentAt
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        // Replace the absolute target frozen at begin, rather than leaving
                        // it to compete with following when the next text arrives.
                        position.value = ScrollPosition(edge: .bottom)
                        proxy.scrollTo(Self.end, anchor: .bottom)
                    }
                }
                shift.onZoomInput = { [zoomRejoining] in
                    if zoomRejoining.value { zoomRejoining.value = false }
                }
                shift.onLetGo = { [widthHold] in widthHold.drop() }
                // Back from behind other windows, a scroll view has come back with nothing drawn.
                shift.onReturn = { [shown] in if shown.value { checkBlank() } }
                if StoryHost.installed {
                    store.storyScroll = { id in
                        following.value = false
                        proxy.scrollTo(id, anchor: .center)
                    }
                    store.storyRebuild = {
                        // A first rebuild each time, whatever the last one left.
                        remounts.value = 0
                        rebuild(geometry.value.offset)
                    }
                    store.storyScrollView = { shift.current }
                }
                // A selection dragged past the edge scrolls as the reader would: nothing pulls it
                // back to the end, or to a place still being restored. Turns going in above as it
                // nears the top keep what's on screen, as for a wheel.
                store.selection.draggedScroll = { [following, restore, restoreInRow, settling] in
                    following.value = false
                    restore.value = nil
                    restoreInRow.value = nil
                    settling.value = nil
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
                shift.onZoomBegin = nil
                shift.onZoomEnd = nil
                shift.onZoomInput = nil
                shift.onLetGo = nil
                store.savedScroll = place(atEnd: following.value)
                // A board's tile may have taken the chat over by now.
                if store.readerView == ObjectIdentifier(following) {
                    store.readerAtEnd = nil
                    store.backAtEnd = nil
                }
                counted.value?.viewsOnScreen -= 1
                counted.value = nil
                actions.unloadOld()
            }
        }
    }

    /// After a new width, how soon it's looked at for nothing drawn.
    private static let blankSoon: TimeInterval = 0.3

    /// Two seconds after it shows, changes or its window comes back, a transcript with rows but
    /// nothing on screen (AppKit's content not under the visible part, or no layer drawing there)
    /// is logged with its geometry in sessions.log ("blank"), and its scroll view is built again:
    /// first where the reader was, then at the end. Never while its window is covered: macOS may
    /// drop what it drew until it shows again.
    private func checkBlank(soon: Bool = false) {
        guard shown.value else {
            blankCheck.value.task?.cancel()
            blankCheck.value.task = nil
            blankCheck.value.soon = false
            return
        }
        if soon {
            // A sooner one, which the moves a new width brings don't put off.
            blankCheck.value.task?.cancel()
            blankCheck.value.task = nil
            blankCheck.value.due = Date().addingTimeInterval(Self.blankSoon)
            blankCheck.value.soon = true
        } else if !blankCheck.value.soon {
            // One check under way, put off by each call (a stream's every move) rather than made anew.
            blankCheck.value.due = Date().addingTimeInterval(2)
        }
        guard blankCheck.value.task == nil else { return }
        let (store, seen, tops, remounts, remountedAt, shift, following, blankCheck) = (store, seen, rowTops, remounts, remountedAt, shift, following, blankCheck)
        let rebuild = rebuild
        blankCheck.value.task = Task { @MainActor in
            while blankCheck.value.due.timeIntervalSinceNow > 0 {
                try? await Task.sleep(for: .seconds(blankCheck.value.due.timeIntervalSinceNow))
                if Task.isCancelled { return }
            }
            blankCheck.value.task = nil
            blankCheck.value.soon = false
            guard !store.sections.isEmpty, seen.value.count == 5, shift.windowVisible || StoryHost.installed else { return }
            let (height, offset, visible) = (seen.value[0], seen.value[1], seen.value[2])
            let frames = shift.frames
            let drawn = shift.drawn
            let unseen = (frames.map { $0.content.height < 1 || !$0.content.intersects($0.visible) } ?? false) || drawn == 0
            // By what's drawn, not by which rows reported: a new chat, or a turn showing only its
            // tool rows, has no message or answer on screen and is fine. SwiftUI's offset can run
            // past its height while AppKit's view is drawn, so it isn't asked.
            guard unseen else {
                if remounts.value > 0 {
                    KoreLog.named("sessions").write("blank-recovered", ["cli": store.providerName])
                    remounts.value = 0
                }
                return
            }
            KoreLog.named("sessions").write(
                "blank",
                [
                    "cli": store.providerName, "chat": store.chatID?(), "sections": String(store.sections.count), "rows": String(store.entries.count),
                    "height": String(Int(height)), "offset": String(Int(offset)), "visible": String(Int(visible)),
                    "tops": String(tops.value.count), "first_top": tops.value.values.min().map { String(Int($0)) },
                    "following": following.value ? "yes" : "no", "remounts": String(remounts.value),
                    "ak_height": frames.map { String(Int($0.content.height)) }, "ak_y": frames.map { String(Int($0.visible.minY)) },
                    "ak_visible": frames.map { String(Int($0.visible.height)) }, "drawn": drawn.map { String($0) },
                ])
            // Twice for one blank (where the reader was, then the end), and a few times a minute
            // in all: each build measures the rows again.
            remountedAt.value.removeAll { $0.timeIntervalSinceNow < -60 }
            guard remounts.value < 2, remountedAt.value.count < 4 else { return }
            remountedAt.value.append(Date())
            rebuild(offset)
            // Then looked at again: drawn now ("blank-recovered"), or logged once more.
            checkBlank()
        }
    }

    /// The scroll view built again, which measures the rows afresh: a lazy stack can keep a height
    /// well past its last row, and nothing draws down there until the view scrolls back above it
    /// (a pin to the end doesn't reach it). A reader above the end comes back to `offset` the
    /// first time (never past the true end); if it's blank again, or they were following, it
    /// goes to the end.
    private func rebuild(_ offset: CGFloat) {
        if !following.value, remounts.value == 0 {
            // The new view's geometry takes it there (`settling`), before anything follows.
            settle(at: offset)
        } else {
            following.value = true
            // Over any glide under way: layout pins the new view to the end at once.
            glidingUntil.value = nil
            glideCut.value = store.sentAt
            position.value = ScrollPosition(edge: .bottom)
        }
        remounts.value += 1
        widthHold.reset()
        shift.release()
        mount.value &+= 1
    }

    /// Turns left memory with nobody looking: a lazy stack would go on from heights it estimated
    /// with those rows, and could come back past its rows with nothing drawn (a pin to the end
    /// doesn't reach it). Out of sight, its scroll view is built anew at the end, so it's laid out
    /// by the time the tab shows, and holds nothing of what left.
    private func renewOutOfSight() {
        guard !store.isOnScreen else { return }
        following.value = true
        glidingUntil.value = nil
        glideCut.value = store.sentAt
        position.value = ScrollPosition(edge: .bottom)
        rowTops.value = [:]
        answerTops.value = [:]
        widthHold.reset()
        shift.release()
        settle(at: nil)
        renewing.value = Date() + Self.settleLimit
        mount.value &+= 1
    }

    /// This view counts its store's chat as on screen while it shows it.
    private func countOnScreen() {
        let now = hidden ? nil : store
        guard counted.value !== now else { return }
        counted.value?.viewsOnScreen -= 1
        now?.viewsOnScreen += 1
        counted.value = now
    }

    /// The reader's place isn't kept through a new width any longer (`WidthHold`).
    private func letGo() {
        widthHold.drop()
        shift.release()
    }

    /// Holds the view at `offset`, or within the measured end, while it lays out (`settling`).
    private func settle(at offset: CGFloat?) {
        let now = Date()
        settling.value = (offset, now + Self.settle, now + Self.settleLimit)
    }

    /// Where the reader is: the row nearest the top of the visible area, and how far below its
    /// top that is (negative: above it). It comes back exactly, however the rows above it
    /// measure when they're built again.
    private func place(atEnd: Bool) -> TranscriptStore.SavedScroll {
        let place = rowTops.value.min { abs($0.value) < abs($1.value) }.map { (key: $0.key, value: -$0.value) }
        return TranscriptStore.SavedScroll(row: place?.key, inRow: place?.value ?? 0, offset: geometry.value.offset, atEnd: atEnd)
    }

    /// Pins the end while following: at once, or gliding for 2s after a send. A send always
    /// brings the end back into view. A tab `showing` again never glides: it's there at once.
    private func follow(_ proxy: ScrollViewProxy, showing: Bool = false) {
        guard !shift.zoomAdjusting else { return }
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
        letGo()
        anchor.value = answerTops.value.filter { $0.value >= 0 }.min { $0.value < $1.value }.map { ($0.key, $0.value, false, false, nil) }
        readerMoved.value = (0, false)
    }

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        return Binding(get: { position.value }, set: { position.value = $0 })
    }

    /// The rows' and the messages' actions, built the first time.
    private func builtActions(_ proxy: ScrollViewProxy) -> (rows: TranscriptActions, reveal: TranscriptActions) {
        if let built = built.value { return built }
        let made = (rows: rowActions(proxy), reveal: reveal(proxy))
        built.value = made
        return made
    }

    /// Rows' actions: scrolling back to a message, and reporting where messages are.
    private func rowActions(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = reveal(proxy)
        let sticky = sticky
        let (tops, answerTops, hold) = (rowTops, answerTops, widthHold)
        let (anchor, readerMoved, geometry, position, nudge, shift, visible) = (anchor, readerMoved, geometry, position, nudge, shift, visibleHeight)
        let (following, opened) = (following, openMessages)
        let scroll = scroll
        // Each row's new frame, and the reader's place kept as the width changes (`WidthHold`).
        let put = { (put: WidthHold.Put?) in
            guard let put, !shift.zoomAdjusting else { return }
            switch put {
            case .hold(let place):
                // Where it's left once the hold ends, with no scroll to report it.
                if case .offset(let offset) = place {
                    geometry.value.offset = offset
                    hold.rest = (offset, false)
                    // Not at the end (a move with no scroll phase left it set): not followed.
                    following.value = false
                } else {
                    hold.rest?.atEnd = true
                }
                shift.hold(place, until: hold.until)
            case .seek(let id):
                shift.release()
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        let moved = { (id: String, top: CGFloat?) in
            tops.value[id] = top
            if top == nil { put(hold.left(id)) }
        }
        let inset = insetTop
        actions.rowPlaced = { id, frame in
            put(hold.placed(id, frame, offset: shift.frames?.visible.minY, inset: inset.value, visible: visible.value, following: following.value))
        }
        actions.messageMoved = { [reading] id, frame in
            sticky.row(id, frame?.maxY)
            reading.value.moved(id, frame?.minY)
            moved(id, frame?.minY)
        }
        // A long message opening grows down from where it is, and closing gives back just that:
        // the end isn't followed meanwhile, so the rows on screen stay put.
        actions.messageOpened = { open in
            if open {
                if opened.value.count == 0 { opened.value.followed = following.value }
                opened.value.count += 1
                if following.value { following.value = false }
            } else if opened.value.count > 0 {
                opened.value.count -= 1
                if opened.value.count == 0, opened.value.followed { following.value = true }
            }
        }
        actions.answerMoved = { id, top in
            answerTops.value[id] = top
            moved(id, top)
            // Back on screen after turns went in above: on by what the move missed.
            guard !shift.zoomAdjusting, let top, let kept = anchor.value, kept.id == id, kept.placed, abs(top) < visible.value else { return }
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

/// A new width (a window's edge or a sash dragged) wraps the rows anew and the lazy stack
/// measures them again, so a place held in points slides. A reader scrolled up is kept by a built
/// row: the one whose top is nearest the top of the visible area at the old width. The view is
/// held where it was (`ScrollShift.hold`), and moved by as much as that row moves in the content
/// as it's laid out again, through the whole drag, however its passes are spread or run together;
/// when it starts above the top, the share of it above stays above, as its text wraps the same way
/// all through. The reader's scroll moves no row in the content, so it's never answered.
@MainActor
private final class WidthHold: ObservableObject {
    enum Put {
        case hold(ScrollShift.Place)
        /// The row was laid out off screen and isn't built: to it, and on from its next frame.
        case seek(String)
    }

    /// For this long after the width last changed, or the row kept last moved, it's held.
    static let lasts: TimeInterval = 1
    private(set) var until = Date.distantPast
    /// The offset the reader left the view at, and whether that was at the end, as the scroll
    /// view last had them at an unchanged width: SwiftUI can move the view for a new width before
    /// any row reports it.
    var rest: (offset: CGFloat, atEnd: Bool)?
    /// The width the rows were last laid out at.
    private var width: CGFloat?
    /// Built message and answer rows' frames in the content.
    private var places: [String: CGRect] = [:]
    /// The row kept: its frame in the content at the width it was taken at, the share of it
    /// above the top of the visible area then, and the view's offset then.
    private var row: (id: String, place: CGRect, share: CGFloat, offset: CGFloat)?

    /// A row is kept: nothing else moves the view or reads where the reader left it meanwhile.
    var holding: Bool { row != nil && Date() < until }
    /// The row kept left the built rows: the view is taken to it until it's built again.
    private(set) var seeking: String?
    /// The other built rows' frames when the row was kept: laid out again with it, they say about
    /// where it went when it leaves the built rows.
    private var witnesses: [String: CGRect] = [:]

    /// A row left the built rows: if it's the row kept, the view is taken to it, and kept.
    func left(_ id: String) -> Put? {
        places[id] = nil
        guard holding, let row, row.id == id else { return nil }
        until = Date() + Self.lasts
        // As far as the nearest row still built at this width moved, at once; it's sought only
        // when none is.
        let moved = witnesses.compactMap { key, was in
            places[key].flatMap { now in abs(now.width - (width ?? now.width)) <= 0.5 ? (abs(was.minY - row.place.minY), now.minY - was.minY) : nil }
        }.min { $0.0 < $1.0 }
        if let moved { return .hold(.offset(row.offset + moved.1)) }
        seeking = id
        return .seek(id)
    }

    /// A row's frame in the content: where the view goes, if it's the row kept. `offset` is the
    /// view's now, `inset` the top inset (the visible area's top is that far below the offset).
    func placed(_ id: String, _ frame: CGRect, offset: CGFloat?, inset: CGFloat, visible: CGFloat, following: Bool) -> Put? {
        let put = take(at: frame.width, offset: offset, inset: inset, visible: visible, following: following)
        places[id] = frame
        // A frame still at the width it was kept at is the lazy stack placing it by its guesses
        // for the rows around while they're laid out again: the next, at the new width, says.
        guard holding, let row, row.id == id, abs(frame.width - (width ?? frame.width)) <= 0.5 else { return put }
        seeking = nil
        until = max(until, Date() + Self.lasts / 4)
        let moved = (frame.minY + row.share * frame.height) - (row.place.minY + row.share * row.place.height)
        return .hold(.offset(row.offset + moved))
    }

    /// The first frame at a new width: unless a row is kept already (a drag under way), the row
    /// kept is taken from the frames still at the old width.
    private func take(at width: CGFloat, offset: CGFloat?, inset: CGFloat, visible: CGFloat, following: Bool) -> Put? {
        defer { self.width = width }
        guard let old = self.width, abs(width - old) > 0.5 else { return nil }
        if following, rest?.atEnd ?? true {
            until = Date() + Self.lasts
            row = nil
            return .hold(.end)
        }
        if holding {
            until = Date() + Self.lasts
            return nil
        }
        until = Date() + Self.lasts
        guard let offset = rest?.offset ?? offset else { return nil }
        // Tops from the top of the visible area.
        let top = offset + inset
        let built = places.filter { abs($0.value.width - old) <= 0.5 }
        row = built.filter { $0.value.minY - top < visible && $0.value.maxY > top }
            .min { abs($0.value.minY - top) < abs($1.value.minY - top) }
            .map { kept in (kept.key, kept.value, kept.value.minY < top && kept.value.height > 0 ? (top - kept.value.minY) / kept.value.height : 0, offset) }
        witnesses = row.map { kept in built.filter { $0.key != kept.id } } ?? [:]
        return .hold(.offset(offset))
    }

    /// No built row reaches below `y` in the content.
    func rowsEnd(above y: CGFloat) -> Bool { places.values.allSatisfy { $0.maxY <= y } }

    /// The reader scrolled, or the view keeps its place another way: nothing is held.
    func drop() {
        row = nil
        seeking = nil
        witnesses = [:]
    }

    /// A scroll view built anew lays its rows out afresh: none of it is a new width.
    func reset() {
        row = nil
        seeking = nil
        witnesses = [:]
        width = nil
        rest = nil
        places = [:]
    }
}

/// The transcript's end (`store.tail`), read here alone: each change is handed on, with whether
/// the tab is hidden, as `[tail, hidden ? 1 : 0]`. Under another tab it holds what it was.
private struct TailWatch: View {
    let store: TranscriptStore
    let hidden: Bool
    let changed: (_ old: [Int], _ new: [Int]) -> Void
    @StateObject private var frozen = Frozen<Int>()

    var body: some View {
        let tail = frozen(hidden) { store.tail }
        Color.clear.onChange(of: [tail, hidden ? 1 : 0], initial: true) { changed($0, $1) }
    }
}

/// A board tile's pinned message: the band the transcript is inset under, reading which
/// messages are stuck. Without a band, no inset.
private struct BandInset: ViewModifier {
    let band: Bool
    let sections: [TranscriptStore.SectionModel]
    let reveal: TranscriptActions
    let tracker: StickyTracker

    func body(content: Content) -> some View {
        if band {
            content.safeAreaInset(edge: .top, spacing: 0) {
                Band(sections: sections, reveal: reveal, tracker: tracker)
            }
        } else {
            content
        }
    }

    private struct Band: View {
        let sections: [TranscriptStore.SectionModel]
        let reveal: TranscriptActions
        @ObservedObject var tracker: StickyTracker

        var body: some View {
            if let section = sections.last(where: { $0.header.map { tracker.stuck.contains($0.id.uuidString) } == true }),
                let header = section.header
            {
                PinnedBand(entry: header, open: section.headerOpen, actions: reveal, tracker: tracker)
            }
        }
    }
}

/// One section, reading only its own model: a streamed token re-renders the section it lands
/// in, not the transcript. Equal by model (its actions are built once). Never wrapped
/// (`.equatable()`): the lazy stack must see its `Section`, or nothing in it is lazy or pinned.
private struct TimelineSection: View, Equatable {
    let section: TranscriptStore.SectionModel
    let actions: TranscriptActions
    let reveal: TranscriptActions
    let sticky: StickyTracker
    @Environment(\.hiddenTab) private var hidden
    /// Its rows as they were when the chat's tab hid.
    @StateObject private var frozen = Frozen<(items: [TranscriptStore.Item], header: TranscriptStore.Entry?, open: Bool)>()

    nonisolated static func == (a: Self, b: Self) -> Bool { a.section === b.section && a.sticky === b.sticky }

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
