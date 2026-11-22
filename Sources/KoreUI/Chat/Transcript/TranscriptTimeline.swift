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
    /// The reader's own inputs on the view (`ScrollShift.readerInputs`) when the end was last
    /// taken up: one since is the reader leaving it (`readerLeft`).
    @StateObject private var followTaken = Held(0)
    @StateObject private var wasFollowing = Held(true)
    /// The reader's inputs as the last shown pass saw them.
    @StateObject private var inputsSeen = Held(0)
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
    /// When the scroll phase went to `.animating`, while it's there.
    @StateObject private var animatingSince = Held<Date?>(nil)
    private static let animationsEnd: TimeInterval = 3
    /// A gesture ended short of the end as its geometry read then: looked at again once the
    /// rows it brought in are measured (a busy Mac measures them a pass or more later). Until
    /// then: later, the view reaching the end is layout's (a fold taking the rows under it), not
    /// the gesture's.
    @StateObject private var endAfterGesture = Held(Date?.none)
    private static let afterGesture: TimeInterval = 1
    /// The last content height and offset, to undo a fold's shrink above the reader.
    @StateObject private var geometry = Held((height: CGFloat(0), offset: CGFloat(0)))
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
    /// A jump is landing: its own moves aren't the reader nearing the top.
    @StateObject private var landingUntil = Held(Date.distantPast)
    /// Turns going in above the reader (earlier turns, the conversation before a compaction): the
    /// built row at the top of the view, with its top from there, as the reader had it. The lazy
    /// stack only estimates the heights above, and re-estimates all of them as rows go in (its
    /// height can drop by thousands of points as turns are added), so neither an offset nor a
    /// change of height says where the row went. In the same update as they go in, the view is
    /// taken to the row with its top where it was (`sought`, `seek`); until then it follows what
    /// the reader has at the top. A fold keeps one the same way, without a seek. Until `until`,
    /// the row is put back at its top by AppKit as it's laid out (`fixKept`), and paging waits.
    @StateObject private var pageKeep = Held((id: String, top: CGFloat, sought: Bool, until: Date)?.none)
    /// The scroll view built again above the end (`rebuild`): the reader's row and its top, kept
    /// as `pageKeep` keeps one once the new view has a height.
    @StateObject private var rebuildKeep = Held((id: String, top: CGFloat, height: CGFloat?)?.none)
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
    /// The text's size (`Zoom`) at the last pass on screen.
    @StateObject private var textScale = Held(CGFloat?.none)
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
    /// The view was taken up onto the rows' end (`checkBlank`): if the next check finds it past
    /// the end again, the scroll view is built again.
    @StateObject private var endPinned = Held(false)
    @StateObject private var shown = Held(false)
    /// The store this view counts as on screen in (`countOnScreen`).
    @StateObject private var counted = Held(TranscriptStore?.none)
    /// The story's scrolls, told apart (`storyScroll`).
    @StateObject private var storyAsks = Held((id: String, count: Int)(id: "", count: 0))

    private static let end = "transcript-end"
    private static let loadRow = "transcript-load-row"
    /// "At the bottom" within this, as in the extension.
    private static let atBottom: CGFloat = 50
    /// This far from the end, a move up without a phase is the reader's, not a pin landing short.
    private static let leftEnd: CGFloat = 150
    /// After a send, new content glides into view for this long.
    private static let glide: TimeInterval = 2

    /// An animated scroll past any of ours: cut short, it never ended.
    private static func stuck(_ since: Date?) -> Bool { since.map { Date().timeIntervalSince($0) > animationsEnd } ?? false }
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
                        LoadEarlierRow(label: "Load earlier turns") { loadEarlier(proxy) }
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
                        pageKeep.value = nil
                        restore.value = nil
                        restoreInRow.value = nil
                        landingUntil.value = Date().addingTimeInterval(Self.landing)
                        // Over a send's glide still under way: its animation outlives this move
                        // and carried the view back to the end, which was followed again.
                        glidingUntil.value = nil
                        glideCut.value = store.sentAt
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        ScrollLog.write("move", "why=rail id=\(id)")
                        shift.aim()
                        withTransaction(instant) { proxy.scrollTo(id, anchor: .top) }
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
                ScrollLog.write("phase", "\(old)->\(new) off=\(ScrollLog.n(context.geometry.contentOffset.y)) follow=\(following.value) in=\(shift.readerInputs)")
                gesturing.value = new != .idle
                // An animated scroll of ours (a glide, a magnification) is over in well under a
                // second; one a scroll with no phase (the scroll bar, End) cut short never says it
                // ended, and is let go after `animationsEnd` (`readerGesturing`).
                if new == .animating { if old != .animating { animatingSince.value = Date() } } else { animatingSince.value = nil }
                // The end the view was taken to can lie below the rows: the check looks when it stops.
                if new == .idle { checkBlank() }
                guard !shift.zoomAdjusting else { return }
                if new == .interacting {
                    zoomRejoining.value = false
                    following.value = false
                    letGo()
                    // The reader took over: a place still being restored or kept is dropped (one
                    // waiting for turns read from disk follows the reader instead).
                    rebuildKeep.value = nil
                    if pageKeep.value?.sought == true { pageKeep.value = nil }
                    restore.value = nil
                    settling.value = nil
                    restoreInRow.value = nil
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                    endAfterGesture.value = following.value ? nil : Date() + Self.afterGesture
                }
                if new != .idle { endAfterGesture.value = nil }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height, $0.contentInsets.top, $0.containerSize.width]
            } action: { old, new in
                let followedBefore = following.value
                if ScrollLog.on {
                    let was = geometry.value
                    let top = new[1] + new[3]
                    let anchor = widthHold.anchor(at: top).map { "\($0.id.prefix(8))@\(ScrollLog.n($0.y))" } ?? "-"
                    ScrollLog.write(
                        "geo",
                        "h=\(ScrollLog.n(new[0])) dh=\(ScrollLog.d(new[0] - was.height)) off=\(ScrollLog.n(new[1])) doff=\(ScrollLog.d(new[1] - was.offset)) "
                            + "vis=\(ScrollLog.n(new[2])) w=\(ScrollLog.n(new[4])) in=\(shift.readerInputs) follow=\(following.value ? 1 : 0) "
                            + "gest=\(gesturing.value ? 1 : 0) hidden=\(hidden ? 1 : 0) anchor=\(anchor) turnsHidden=\(store.hiddenTurns)")
                }
                defer {
                    if following.value != followedBefore { ScrollLog.write("follow", "\(followedBefore ? 1 : 0)->\(following.value ? 1 : 0)") }
                }
                shift.laidOut(at: new[1])
                seen.value = new
                // Where the reader left it (`WidthHold`): at an unchanged width, and not while a
                // new one is still being laid out (held).
                if !shift.keep(), !widthHold.holding, old.count == new.count, new[4] == old[4] {
                    // The content's height is partly estimated: at its end only with no built row
                    // reaching past the bottom of the view. Followed, a row still being laid out
                    // past it is the end coming (pinned to as it lands), not a reader above it; and
                    // so is content that grew in this pass, before the pin below brings the view to
                    // it (a busy Mac can change the width next, with no pass between to read it). A
                    // followed end only the reader's own input leaves is the end, wherever this pass
                    // has the view: one rebuilt lays out from the top while it's pinned.
                    let grew = following.value && new[0] > old[0]
                    let pinned = following.value && !Self.readerLeft(inputs: shift.readerInputs, taken: followTaken.value)
                    widthHold.rest = (new[1], grew || pinned || (new[1] + new[2] >= new[0] - Self.atBottom
                        && (following.value || widthHold.rowsEnd(above: new[1] + new[3] + new[2] + Self.atBottom))))
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
                    if Date() >= until || Self.readerLeft(inputs: shift.readerInputs, taken: followTaken.value) {
                        renewing.value = nil
                    } else if following.value {
                        renewed = true
                        if abs(offset + new[2] - height) > 1 {
                            ScrollLog.write("move", "why=renew-pin")
                            var instant = Transaction()
                            instant.disablesAnimations = true
                            shift.aim()
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
                let shownBefore = seenShown.value
                seenShown.value = new
                // The text's size changed (⌘+ / ⌘-) under a reader at the end there by a move that
                // took nothing up (a zoom out that left the view at the end): followed, so the pin
                // below keeps the end in view as the text reflows, as `readerAtEnd` has it.
                let scale = Zoom.shared.scale
                if let was = textScale.value, was != scale, !following.value, !shift.zoomAdjusting,
                    shownBefore.count == 5, shownBefore[1] + shownBefore[2] >= shownBefore[0] - Self.atBottom
                {
                    ScrollLog.write("follow", "zoom-at-end")
                    following.value = true
                    followTaken.value = shift.readerInputs
                }
                textScale.value = scale
                // The end taken up again, or still there with nothing moved up (a wheel turned down
                // at the end): the reader's inputs before this pass are behind it (one that came
                // with this pass's move is that move's).
                let atEnd = offset + new[2] >= height - Self.atBottom
                if Self.takesEnd(following: following.value, was: wasFollowing.value, atEnd: atEnd, movedUp: offset < geometry.value.offset - 1) {
                    followTaken.value = inputsSeen.value
                }
                // The reader's own input came with this pass's move: theirs, not one of Kore's
                // jumps landing (the rail, a reveal) or layout's.
                let readerMovedNow = shift.readerInputs != inputsSeen.value
                inputsSeen.value = shift.readerInputs
                wasFollowing.value = following.value
                let readerLeft = Self.readerLeft(inputs: shift.readerInputs, taken: followTaken.value)
                // A move with no scroll phase (the scroll bar, End) never reaches `.idle` above.
                // A new width can leave the content's height past its rows: looked at soon.
                if old.count == new.count, old[4] > 0, new[4] != old[4] {
                    // A reader above the end (a row kept through the steps before, or where they
                    // left it at the first): SwiftUI, which keeps the view on a row it picks as
                    // content is laid out again, can carry it far off by its estimates and take
                    // the row kept out of the built rows (a seek then lands at the end of an
                    // estimated height). Held at a point instead, it's where the hold has it (or
                    // the reader left it), and the row's frames at the new width move it.
                    widthHold.resized()
                    let held: CGFloat? = if widthHold.holding, case .offset(let y) = shift.held?.place {
                        y
                    } else if !widthHold.holding, !following.value, let rest = widthHold.rest, !rest.atEnd {
                        rest.offset
                    } else {
                        nil
                    }
                    if let y = held, !shift.zoomAdjusting,
                        position.value.isPositionedByUser || position.value.point.map({ abs($0.y - y - insetTop.value) > 0.5 }) ?? true
                    {
                        scroll(position, to: y, why: "width-held")
                        nudge.value &+= 1
                    }
                    checkBlank(soon: true)
                }
                // A jump of more than two screens (End, the scroll bar, a storyline) can land
                // where the lazy stack builds no rows: looked at soon rather than in 2 s.
                if !gesturing.value, offset != geometry.value.offset { checkBlank(soon: abs(offset - geometry.value.offset) > 2 * new[2]) }
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
                    if widthHold.rest?.atEnd ?? true || !readerLeft {
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
                    ScrollLog.write("move", "why=width-seek id=\(id)")
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    shift.aim()
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
                    scroll(position, to: target, why: "restore-in-row")
                    geometry.value = (height, target)
                    nudge.value &+= 1
                    return
                }
                if let saved = restore.value, height > 0 {
                    // Back to where the reader was when this chat's tab was last shown.
                    restore.value = nil
                    if !saved.atEnd {
                        // A glide the new view began toward the end, followed as it appeared, is
                        // over: the reader's place is where it goes.
                        following.value = false
                        glidingUntil.value = nil
                        glideCut.value = store.sentAt
                        settle(at: nil)
                        if let row = saved.row {
                            ScrollLog.write("move", "why=restore-row id=\(row)")
                            shift.aim()
                            proxy.scrollTo(row, anchor: .top)
                            restoreInRow.value = saved.inRow
                        } else {
                            // Never past the end: the content can be shorter than when it was left.
                            let target = min(saved.offset, max(0, height - new[2]))
                            scroll(position, to: target, why: "restore-offset")
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
                            scroll(position, to: target, why: "settling")
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
                if let kept = rebuildKeep.value, height > 0 {
                    rebuildKeep.value = nil
                    pageKeep.value = (kept.id, kept.top, true, Date() + Self.settleLimit)
                    ScrollLog.write("move", "why=rebuild-seek id=\(kept.id) top=\(ScrollLog.n(kept.top))")
                    seek(proxy, (kept.id, kept.top, kept.height))
                    geometry.value = (height, offset)
                    return
                }
                if let kept = pageKeep.value {
                    if Date() >= kept.until {
                        pageKeep.value = nil
                    } else if !kept.sought, offset != geometry.value.offset, let row = widthHold.anchor(at: offset + new[3]) {
                        // Still to come: what the reader has at the top now.
                        pageKeep.value = (row.id, row.y, false, kept.until)
                    }
                }
                if insetSettling.value, !following.value || gesturing.value || offset + new[2] >= height - Self.atBottom {
                    insetSettling.value = false
                }
                // Moved up, away from the end, by the reader with no scroll phase: the scroll bar, a
                // wheel, Page Up. Stop following, or each row measured on the way would pull the view
                // back to the end. Only the reader's (`ScrollShift.readerInputs`): the lazy stack
                // measuring rows and SwiftUI settling a pin or a glide move it up too, in passes of
                // their own, with nobody scrolling. Only once there's more than a screen (a shorter
                // chat sits at the bottom and moves as it grows), and only well clear of the end.
                if !shift.zoomAdjusting, following.value, !widthHeld, !renewed, !insetSettling.value,
                    Self.leavesEnd(readerLeft: readerLeft, height: height, visible: new[2], offset: offset, was: geometry.value.offset)
                {
                    following.value = false
                }
                // And back: moved down to within the slack of the end the same way (the scroll bar,
                // Page Down, End) starts following again, as a phased scroll ending there does,
                // even while a reply streams in. Only between gestures, and only on a move down:
                // content arriving under a reader held just above the end doesn't move them, so
                // it doesn't pull them along. Not while a view new or built again settles: it lays
                // out from the bottom before a place being restored lands.
                // The first settled pass after a gesture that ended short: at the end by now, it's
                // followed, as if the gesture had ended there.
                if let until = endAfterGesture.value, Date() >= until { endAfterGesture.value = nil }
                if endAfterGesture.value != nil, !gesturing.value, height == geometry.value.height {
                    endAfterGesture.value = nil
                    if !shift.zoomAdjusting, !following.value, offset + new[2] >= height - Self.atBottom { following.value = true }
                }
                if !shift.zoomAdjusting, !following.value, !widthHeld, !gesturing.value || Self.stuck(animatingSince.value), readerMovedNow,
                    Self.movesToEnd(settling: settling.value != nil, height: height, visible: new[2], offset: offset, was: geometry.value.offset)
                {
                    following.value = true
                }
                // Rows measured after they were placed change the height: while following, stay
                // pinned to the end through layout (`pinsEnd`).
                if !shift.zoomAdjusting, following.value, !widthHeld,
                    Self.pinsEnd(grew: height != geometry.value.height, insetSettling: insetSettling.value, visibleMoved: visibleMoved, magnified: shift.isMagnified),
                    glidingUntil.value.map({ Date() >= $0 }) ?? true
                {
                    ScrollLog.write("move", "why=pin-end grew=\(height != geometry.value.height) inset=\(insetSettling.value) vis=\(visibleMoved)")
                    pinEnd(proxy)
                }
                // Within a screen of the top on the way up: earlier turns go in above, as the top
                // row's press does, with what's on screen kept where it is. Only the reader's own
                // scroll: never a place being restored (a tab coming back).
                if !following.value, restore.value == nil, restoreInRow.value == nil, pageKeep.value == nil,
                    !fetching.value, !widthHeld, offset < geometry.value.offset - 1, offset + insetTop.value < new[2], Date() >= landingUntil.value
                {
                    // The row kept is the one the reader has at the top now, after this move.
                    geometry.value = (height, offset)
                    if store.hiddenTurns > 0 {
                        loadEarlier(proxy)
                    } else if store.earlierAvailable, !store.loadingEarlier {
                        loadEarlierConversation()
                    }
                }
                geometry.value = (height, offset)
            }
            // A history read again brings a store of its own, under this same view.
            .onChange(of: ObjectIdentifier(store), initial: true) {
                reading.value.isFollowing = { [following] in following.value }
                // Following it, or there by a move that didn't say so.
                store.readerAtEnd = { [following, gesturing, animatingSince, restore, restoreInRow, shift, seenShown] in
                    let seen = seenShown.value
                    let atEnd = following.value || (seen.count == 5 && seen[1] + seen[2] >= seen[0] - Self.atBottom)
                    let moving = gesturing.value && !Self.stuck(animatingSince.value)
                    return atEnd && !moving && restore.value == nil && restoreInRow.value == nil && !shift.zoomAdjusting
                }
                store.storyEndWhy = { [following, gesturing, restore, restoreInRow, shift, seenShown] in
                    "following \(following.value), gesturing \(gesturing.value), restore \(restore.value != nil), in row \(restoreInRow.value != nil), zoom \(shift.zoomAdjusting), seen \(seenShown.value)"
                }
                // Rows gone while it was out of sight are laid out by now: the end is at once where
                // the end row is, whatever the rows above it were estimated at.
                store.backAtEnd = { [following, glidingUntil, glideCut, weak store = store] in
                    following.value = true
                    glidingUntil.value = nil
                    glideCut.value = store?.sentAt
                    ScrollLog.write("move", "why=back-at-end")
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    shift.aim()
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
            .onChange(of: sections.isEmpty) { _, empty in if !empty { landHistory(sections.count) } }
            .onChange(of: store.folded?.seq) {
                ScrollLog.write("fold", "following=\(following.value)")
                letGo()
                // Its work rows all go in one update, and AppKit's document can keep the height
                // they had: at the end, the end is looked at soon (a glide doesn't put it off).
                // Above it, the row the reader has at the top stays where it is, as rows going in
                // above do (`pageKeep`): work folding under it moves nothing, work folding above it
                // doesn't take the view up with it. The rows' frames are still the ones before.
                let kept = widthHold.anchor(at: geometry.value.offset + insetTop.value)
                switch FoldMove(following: following.value, kept: kept) {
                case .checkEnd:
                    // A pin of its own: an earlier check's isn't this one's.
                    endPinned.value = false
                    // A send's glide under way holds layout's pin off and animates to the end the
                    // content had: the work folding away can leave the view far past the rows' end,
                    // blank, till it's over. Followed, the end is where it's going anyway: cut to it
                    // now (the rest of the reply is pinned at once, `glideCut`).
                    // Only content taller than the view can leave it past the rows' end: a short
                    // chat's glide ends where it is (cut, SwiftUI's place and AppKit's part
                    // ways by the glide's distance, and VoiceOver finds its rows that far off).
                    if glidingUntil.value.map({ Date() < $0 }) ?? false, geometry.value.height > visibleHeight.value {
                        ScrollLog.write("move", "why=fold-cuts-glide")
                        glidingUntil.value = nil
                        glideCut.value = store.sentAt
                        pinEnd(proxy)
                    }
                    checkBlank(soon: true)
                case .keep(let id, let top):
                    pageKeep.value = (id, top, true, Date() + Self.landing)
                case .stay:
                    break
                }
            }
            .onChange(of: store.loadingEarlier) { _, loading in
                // The earlier conversation is in (and laid out next): what's on screen stays.
                if !loading, fetching.value {
                    ScrollLog.write("earlier-in", "height=\(ScrollLog.n(geometry.value.height))")
                    fetching.value = false
                    seekKept(proxy)
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
                    // Rows came while it was out of sight: at the end, it's built anew there before
                    // it draws (pins aimed at their estimates don't converge).
                    if Self.renewsOnShow(showing: showing, grew: old[0] != new[0], following: following.value, magnified: shift.isMagnified) {
                        renewAtEnd()
                        return
                    }
                    follow(proxy, showing: showing)
                }
            }
            .onAppear {
                // A move up off a followed end stays once it's clear of it (`leavesEnd`).
                shift.readerKeeps = { [following] by in !following.value || by < -Self.leftEnd }
                // The reader scrolls on as turns go in above: the row kept goes with them.
                shift.onReaderMoved = { [pageKeep] by in
                    if pageKeep.value?.sought == true { pageKeep.value?.top -= by }
                }
                shift.onMagnified = { [sticky] in sticky.magnified.set($0) }
                shift.onZoomBegin = { [glidingUntil, glideCut, store, position, nudge, geometry, insetTop, following, zoomFollowing, zoomRejoining, zoomBegan, shift] native in
                    zoomFollowing.value = following.value
                    zoomBegan.value = native
                    // The pinch holds the page itself: nothing else does meanwhile.
                    shift.release()
                    zoomRejoining.value = false
                    glidingUntil.value = nil
                    glideCut.value = store.sentAt
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        // ScrollPosition counts from SwiftUI's content origin. A native
                        // clip origin already includes a different inset conversion.
                        shift.aim()
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
                        // it to compete with following when the next text arrives. A magnified
                        // page keeps its side: no edge target, pinned up or down natively.
                        if shift.isMagnified {
                            position.value = ScrollPosition()
                            shift.hold(.end, until: Date() + Self.landing)
                        } else {
                            position.value = ScrollPosition(edge: .bottom)
                            shift.aim()
                            proxy.scrollTo(Self.end, anchor: .bottom)
                        }
                    }
                }
                shift.onZoomInput = { [zoomRejoining] in
                    if zoomRejoining.value { zoomRejoining.value = false }
                }
                shift.onLetGo = { [widthHold] in widthHold.drop() }
                widthHold.order = { [weak store = store] in store?.sections.flatMap { $0.items.map(\.id) } ?? [] }
                // Back from behind other windows, a scroll view has come back with nothing drawn.
                shift.onReturn = { [shown] in if shown.value { checkBlank() } }
                if StoryHost.installed {
                    store.storyScroll = { id in
                        ScrollLog.write("move", "why=story id=\(id)")
                        following.value = false
                        // Asked again and again for a row it doesn't build: SwiftUI can keep a
                        // row's place from before a fold took the rows above it out, and lands
                        // every `scrollTo` there. Built again once, it measures them afresh.
                        storyAsks.value = storyAsks.value.id == id ? (id, storyAsks.value.count + 1) : (id, 1)
                        if storyAsks.value.count == 60 {
                            ScrollLog.write("move", "why=story-rebuild id=\(id)")
                            remounts.value = 0
                            rebuild(geometry.value.offset)
                            return
                        }
                        shift.aim()
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
                                shift.aim()
                                proxy.scrollTo(divider.id, anchor: .center)
                            } else {
                                shift.aim()
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
                shift.readerKeeps = nil
                shift.onReaderMoved = nil
                shift.onMagnified = nil
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
        let endPinned = endPinned
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
            // Or partly blank: the view's bottom past the rows' end (SwiftUI's height), on a
            // document AppKit still sizes as it was before rows went (a turn's work folding away).
            let past = !unseen && shift.past(end: height, slack: Self.atBottom)
            // By what's drawn, not by which rows reported: a new chat, or a turn showing only its
            // tool rows, has no message or answer on screen and is fine. SwiftUI's offset can run
            // past its height while AppKit's view is drawn, so it isn't asked.
            guard unseen || past else {
                endPinned.value = false
                if remounts.value > 0 {
                    KoreLog.named("sessions").write("blank-recovered", ["cli": store.providerName])
                    remounts.value = 0
                }
                return
            }
            // First, at once and natively, the view's bottom onto the rows' end; looked at again
            // soon, and built again only when it's still past it then.
            if past, !endPinned.value {
                KoreLog.named("sessions").write(
                    "blank-end",
                    [
                        "cli": store.providerName, "end": String(Int(height)), "following": following.value ? "yes" : "no",
                        "ak_height": frames.map { String(Int($0.content.height)) }, "ak_bottom": frames.map { String(Int($0.visible.maxY)) },
                    ])
                ScrollLog.write("blank-end", "end=\(ScrollLog.n(height)) ak=\(frames.map { ScrollLog.n($0.content.height) } ?? "-")")
                endPinned.value = shift.pinEnd(at: height)
                checkBlank(soon: true)
                return
            }
            endPinned.value = false
            ScrollLog.write("blank", "height=\(ScrollLog.n(height)) offset=\(ScrollLog.n(offset)) drawn=\(drawn.map(String.init) ?? "-") unseen=\(unseen)")
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
            // Back on the reader's row, as a tab coming back is (`restore`): the new view only
            // estimates the rows' heights, so the same offset is somewhere else in it. Without a
            // row placed, the offset; the new view's geometry takes it there (`settling`), before
            // anything follows.
            if let row = widthHold.anchor(at: offset + insetTop.value) {
                rebuildKeep.value = (row.id, row.y, widthHold.height(of: row.id))
            } else {
                settle(at: offset)
            }
        } else {
            following.value = true
            // Over any glide under way: layout pins the new view to the end at once.
            glidingUntil.value = nil
            glideCut.value = store.sentAt
            position.value = ScrollPosition(edge: .bottom)
        }
        ScrollLog.write("rebuild", "offset=\(ScrollLog.n(offset)) following=\(following.value) remounts=\(remounts.value)")
        remounts.value += 1
        reading.value.rowsGone()
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
        renewAtEnd()
    }

    /// The scroll view built anew at the end, laid out from there (`renewing`).
    private func renewAtEnd() {
        ScrollLog.write("renew-at-end")
        following.value = true
        // The reader's inputs so far are behind it: one at the very end (a wheel turned there)
        // moves nothing, so no pass takes it up, and it isn't the reader leaving the new view.
        inputsSeen.value = shift.readerInputs
        followTaken.value = shift.readerInputs
        glidingUntil.value = nil
        glideCut.value = store.sentAt
        position.value = ScrollPosition(edge: .bottom)
        rowTops.value = [:]
        reading.value.rowsGone()
        widthHold.reset()
        shift.release()
        settle(at: nil)
        renewing.value = Date() + Self.settleLimit
        mount.value &+= 1
    }

    /// A history landing all at once in a view that held nothing: the lazy stack placed none of
    /// it, so its pin to the end aims at heights it estimated, and can rest past the rows' end
    /// with nothing drawn. Looked at soon rather than in 2 s (`checkBlank`), which brings the end
    /// back onto the rows, or builds the scroll view again at the end. A first send isn't a history.
    private func landHistory(_ sections: Int) {
        guard sections > 1, following.value, store.sentAt == nil else { return }
        checkBlank(soon: true)
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
            followTaken.value = shift.readerInputs
        }
        guard following.value else { return }
        if shift.isMagnified {
            // A magnified page goes to the end at once, up or down only, keeping its side: no
            // glide (SwiftUI's scroll doesn't count the magnification, and centres the page).
            glidingUntil.value = nil
            glideCut.value = store.sentAt
            ScrollLog.write("move", "why=follow-magnified")
            pinEnd(proxy)
            return
        }
        let glideEnd = store.sentAt.map { $0.addingTimeInterval(Self.glide) }
        if !showing, !reduceMotion, store.sentAt != glideCut.value, let glideEnd, Date() < glideEnd {
            if glidingUntil.value != glideEnd { landGlide(proxy, at: glideEnd) }
            glidingUntil.value = glideEnd
            ScrollLog.write("move", "why=glide")
            shift.aim()
            withAnimation(Motion.glide) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else if showing {
            // Over any glide it hid in the middle of.
            glidingUntil.value = nil
            glideCut.value = store.sentAt
            ScrollLog.write("move", "why=follow-showing")
            var instant = Transaction()
            instant.disablesAnimations = true
            shift.aim()
            withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
        } else {
            ScrollLog.write("move", "why=follow")
            shift.aim()
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// When a send's glide is over, the end once more, at once: the glide aimed at the heights the
    /// lazy stack had then, and rows measured taller under it aren't pinned meanwhile, so it can
    /// stop short of the end with nothing left to bring it there. One look per send; not once the
    /// reader has moved the view.
    private func landGlide(_ proxy: ScrollViewProxy, at end: Date) {
        let (following, glidingUntil, shift, taken) = (following, glidingUntil, shift, followTaken)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end.timeIntervalSinceNow) + 0.05) { [weak store] in
            // Another send's glide, or one a tab switch or a new width cut: not this one's to land.
            guard glidingUntil.value == end else { return }
            glidingUntil.value = nil
            guard following.value, store?.hidden == false, !shift.zoomAdjusting, !shift.isMagnified,
                !Self.readerLeft(inputs: shift.readerInputs, taken: taken.value)
            else { return }
            ScrollLog.write("move", "why=land-glide")
            var instant = Transaction()
            instant.disablesAnimations = true
            shift.aim()
            withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// The reader moved the view themselves since the end was taken up.
    static func readerLeft(inputs: Int, taken: Int) -> Bool { inputs != taken }

    /// The reader's inputs so far are behind a followed end: it was just taken up, or the view is
    /// at it with nothing moved up.
    static func takesEnd(following: Bool, was: Bool, atEnd: Bool, movedUp: Bool) -> Bool {
        following && (!was || atEnd && !movedUp)
    }

    /// A followed view moved up `was` → `offset` leaves the end: the reader's move, well clear of
    /// the end, in a chat taller than a screen. A move of layout's never does, whatever the pass
    /// measured; the reader's does even in a pass that measured rows too.
    static func leavesEnd(readerLeft: Bool, height: CGFloat, visible: CGFloat, offset: CGFloat, was: CGFloat) -> Bool {
        readerLeft && height > visible + atBottom && offset < was - 1 && offset + visible < height - leftEnd
    }

    /// A view not followed moved down `was` → `offset` to within the slack of the end takes it up
    /// again; not while a view new or built again settles, laid out from the bottom before the
    /// place it's restored to lands.
    static func movesToEnd(settling: Bool, height: CGFloat, visible: CGFloat, offset: CGFloat, was: CGFloat) -> Bool {
        !settling && offset > was + 1 && offset + visible >= height - atBottom
    }

    /// A tab shown again with rows that came while it was hidden, and following: built anew at
    /// the end. Not a magnified page, which keeps its own place (`PinchZoom`).
    static func renewsOnShow(showing: Bool, grew: Bool, following: Bool, magnified: Bool) -> Bool {
        showing && grew && following && !magnified
    }

    /// Whether layout pins a followed end: new content or rows measured anew (a new height), an
    /// inset's move, and the visible height's (a card or the composer growing under it), as T3
    /// Code does. Not a magnified page's visible height: the zoomed view stays where it is, only
    /// shorter or taller at the bottom, until new content or a send moves it.
    static func pinsEnd(grew: Bool, insetSettling: Bool, visibleMoved: Bool, magnified: @autoclosure () -> Bool) -> Bool {
        grew || insetSettling || visibleMoved && !magnified()
    }

    /// Pins the end at once. A magnified page moves up or down only, keeping the side it was
    /// moved to; `scrollTo` with `.bottom` would centre it. It's held there natively through the
    /// layout that follows (`ScrollShift.hold`): AppKit sizes its document after SwiftUI reports
    /// the new height, and SwiftUI, which doesn't count the magnification, can move it meanwhile.
    private func pinEnd(_ proxy: ScrollViewProxy) {
        if shift.isMagnified {
            shift.hold(.end, until: Date() + Self.landing)
        } else {
            // At once, whatever transaction layout runs in (a glide's would animate it, and an
            // animation under way outlives a reader's move).
            var instant = Transaction()
            instant.disablesAnimations = true
            shift.aim()
            withTransaction(instant) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// Scrolls so the scroll view's offset (as its geometry reports it) becomes `offset`.
    private func scroll(_ position: Held<ScrollPosition>, to offset: CGFloat, why: String) {
        ScrollLog.write("move", "why=\(why) to=\(ScrollLog.n(offset)) from=\(ScrollLog.n(geometry.value.offset))")
        shift.aim()
        position.value.scrollTo(y: offset + insetTop.value)
    }

    /// Twenty more turns above; what's on screen stays where it was (`pageKeep`).
    private func loadEarlier(_ proxy: ScrollViewProxy) {
        ScrollLog.write("load-earlier", "hidden=\(store.hiddenTurns) height=\(ScrollLog.n(geometry.value.height))")
        keepPlace(until: Date() + Self.landing)
        store.loadEarlier()
        seekKept(proxy)
    }

    /// The conversation before a compaction; it arrives later (read from disk), and what's on
    /// screen then stays where it was.
    private func loadEarlierConversation() {
        ScrollLog.write("load-earlier-conversation", "height=\(ScrollLog.n(geometry.value.height))")
        // However long it takes to read (a busy Mac took 20 s).
        keepPlace(until: .distantFuture)
        fetching.value = true
        actions.loadEarlierConversation()
    }

    /// The row at the top of the view is kept through what goes in above (`pageKeep`).
    private func keepPlace(until: Date) {
        following.value = false
        letGo()
        pageKeep.value = widthHold.anchor(at: geometry.value.offset + insetTop.value).map { ($0.id, $0.y, false, until) }
    }

    /// The row kept (`pageKeep`), laid out at `frame` (in the content): back at its top, by AppKit,
    /// in the same pass. (Waiting for AppKit's document to take the layout first left SwiftUI's
    /// seek unlanded, holding the reader's next flings.)
    private func fixKept(_ id: String, _ frame: CGRect) {
        guard let kept = pageKeep.value, kept.id == id, kept.sought, !shift.zoomAdjusting else { return }
        guard Date() < kept.until else {
            pageKeep.value = nil
            return
        }
        guard let clip = shift.frames?.visible.minY else { return }
        let dy = frame.minY - kept.top - insetTop.value - clip
        guard abs(dy) > 0.5 else { return }
        ScrollLog.write("move", "why=page-keep id=\(id) by=\(ScrollLog.d(dy))")
        _ = shift(dy)
        geometry.value.offset = clip + dy
    }

    /// In the update the turns go in: to the row kept, its top where it was (`seek`).
    private func seekKept(_ proxy: ScrollViewProxy) {
        guard let kept = pageKeep.value else { return }
        pageKeep.value = (kept.id, kept.top, true, Date() + Self.landing)
        ScrollLog.write("move", "why=page-seek id=\(kept.id) top=\(ScrollLog.n(kept.top))")
        seek(proxy, (kept.id, kept.top, widthHold.height(of: kept.id)))
    }

    /// To the row kept, with its top where it was: SwiftUI holds a `scrollTo`'s row and anchor
    /// and lays the view out on them again at each layout after, so the anchor is the place
    /// itself. A unit point `a` puts the row's point `a` of its height on the visible area's
    /// point `a` of its height: its top lands at `a × (visible − height)`.
    private func seek(_ proxy: ScrollViewProxy, _ kept: (id: String, top: CGFloat, height: CGFloat?)) {
        let visible = visibleHeight.value - insetTop.value
        var anchor = UnitPoint.top
        if let height = kept.height, abs(visible - height) > 1 { anchor = UnitPoint(x: 0, y: kept.top / (visible - height)) }
        var instant = Transaction()
        instant.disablesAnimations = true
        shift.aim()
        withTransaction(instant) { proxy.scrollTo(kept.id, anchor: anchor) }
    }

    private var binding: Binding<ScrollPosition> {
        _ = nudge.value
        ScrollLog.write("body", "nudge=\(nudge.value) position=\(position.value)")
        return Binding(get: { position.value }, set: { new in
            ScrollLog.write("bind-set", "\(new)")
            position.value = new
        })
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
        let (tops, hold) = (rowTops, widthHold)
        let (geometry, shift, visible) = (geometry, shift, visibleHeight)
        let fixKept = fixKept
        let (following, opened, taken) = (following, openMessages, followTaken)
        // Each row's new frame, and the reader's place kept as the width changes (`WidthHold`).
        let put = { (put: WidthHold.Put?) in
            guard let put, !shift.zoomAdjusting else { return }
            switch put {
            case .hold(let place):
                // Where it's left once the hold ends, with no scroll to report it.
                if case .offset(let offset) = place {
                    geometry.value.offset = offset
                    hold.rest = (offset, false)
                    // Not at the end (a move of the reader's left it set): not followed.
                    if Self.readerLeft(inputs: shift.readerInputs, taken: taken.value) { following.value = false }
                } else {
                    hold.rest?.atEnd = true
                }
                ScrollLog.write("hold", "why=width place=\(place)")
                shift.hold(place, until: hold.until)
            case .seek(let id):
                ScrollLog.write("move", "why=width-put-seek id=\(id)")
                shift.release()
                var instant = Transaction()
                instant.disablesAnimations = true
                shift.aim()
                withTransaction(instant) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        let moved = { (id: String, top: CGFloat?) in
            tops.value[id] = top
            if top == nil { put(hold.left(id)) }
        }
        let inset = insetTop
        actions.rowPlaced = { id, frame in
            fixKept(id, frame)
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
            moved(id, top)
        }
        return actions
    }

    private func reveal(_ proxy: ScrollViewProxy) -> TranscriptActions {
        var actions = actions
        actions.reveal = { id in
            ScrollLog.write("move", "why=reveal id=\(id)")
            following.value = false
            shift.aim()
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

/// What a turn folding does to the view: its work rows all go in one update.
enum FoldMove: Equatable {
    /// Following the end: it's looked at soon for rows ending above the view's bottom.
    case checkEnd
    /// Above the end: this row stays at this top (from the top of the visible area): the built
    /// row at the top of the view, or the first below it.
    case keep(id: String, top: CGFloat)
    /// No row built there: nothing moves (the content stays where it is, only shorter).
    case stay

    init(following: Bool, kept: (id: String, y: CGFloat)?) {
        if following {
            self = .checkEnd
        } else if let kept {
            self = .keep(id: kept.id, top: kept.y)
        } else {
            self = .stay
        }
    }
}

/// A new width (a window's edge or a sash dragged) wraps the rows anew and the lazy stack
/// measures them again, so a place held in points slides. A reader scrolled up is kept by a built
/// row: the one whose top is nearest the top of the visible area at the old width. The view is
/// held where it was (`ScrollShift.hold`), and moved by as much as that row moves in the content
/// as it's laid out again, through the whole drag, however its passes are spread or run together;
/// when it starts above the top, the share of it above stays above, as its text wraps the same way
/// all through. The reader's scroll moves no row in the content, so it's never answered.
@MainActor
final class WidthHold: ObservableObject {
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

    /// The row kept hasn't been laid out at the width now yet: it's held until it has, however
    /// late that comes (a busy Mac lays rows out more than `lasts` after the width changed, and a
    /// hold gone by then let them move the reader), up to `waitsAtMost` more.
    private var unplaced = false
    static let waitsAtMost: TimeInterval = 10
    /// At the end through a new width: held there while its rows are laid out at it, each one
    /// laid out holding it a little longer (a busy Mac spreads that over more than `lasts`, and a
    /// pass after the hold ended read the view as moved off the end), up to `waitsAtMost`.
    private var endSince: Date?

    /// A row is kept: nothing else moves the view or reads where the reader left it meanwhile.
    var holding: Bool {
        guard row != nil else { return false }
        let now = Date()
        return now < until || (unplaced && now < until + Self.waitsAtMost)
    }
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
        // Not laid out at the new width yet: SwiftUI carried the view off it (keeping a row it
        // picked, by its estimates), the row didn't move. The hold puts the view back, and the
        // row's first frame at the new width moves it; a seek lands by those estimates (at the
        // end of an estimated height).
        guard !unplaced else { return nil }
        seeking = id
        return .seek(id)
    }

    /// A row's frame in the content: where the view goes, if it's the row kept. `offset` is the
    /// view's now, `inset` the top inset (the visible area's top is that far below the offset).
    func placed(_ id: String, _ frame: CGRect, offset: CGFloat?, inset: CGFloat, visible: CGFloat, following: Bool) -> Put? {
        let put = take(at: frame.width, offset: offset, inset: inset, visible: visible, following: following)
        places[id] = frame
        heights[id] = frame.height
        if case .none = put, let since = endSince, abs(frame.width - (width ?? frame.width)) <= 0.5 {
            let now = Date()
            guard following, now < since + Self.waitsAtMost else {
                endSince = nil
                return nil
            }
            until = max(until, now + Self.lasts / 4)
            return .hold(.end)
        }
        // A frame still at the width it was kept at is the lazy stack placing it by its guesses
        // for the rows around while they're laid out again: the next, at the new width, says.
        if let was = stale, row?.id == id {
            guard abs(frame.width - was) > 0.5 else { return put }
            stale = nil
        }
        guard holding, let row, abs(frame.width - (width ?? frame.width)) <= 0.5 else { return put }
        guard row.id == id else {
            // The row kept left the built rows before it was laid out at this width: a row laid
            // out with it at the old width says where it went, as it's laid out at this one.
            guard unplaced, places[row.id] == nil, let was = witnesses[id] else { return put }
            until = max(until, Date() + Self.lasts / 4)
            return .hold(.offset(row.offset + frame.minY - was.minY))
        }
        unplaced = false
        seeking = nil
        until = max(until, Date() + Self.lasts / 4)
        let moved = (frame.minY + row.share * frame.height) - (row.place.minY + row.share * row.place.height)
        return .hold(.offset(row.offset + moved))
    }

    /// The first frame at a new width: unless a row is kept already (a drag under way), the row
    /// kept is taken from the frames still at the old width.
    private func take(at width: CGFloat, offset: CGFloat?, inset: CGFloat, visible: CGFloat, following: Bool) -> Put? {
        guard let old = self.width else {
            self.width = width
            return nil
        }
        guard abs(width - old) > 0.5 else { return nil }
        // With a row kept, another row placed by the lazy stack's guesses at the width the view
        // just left: not a new width (the rows' width stays the new one, for the frames after).
        if holding, let before, abs(width - before) <= 0.5 { return nil }
        self.width = width
        if following, rest?.atEnd ?? true {
            until = Date() + Self.lasts
            row = nil
            endSince = Date()
            return .hold(.end)
        }
        endSince = nil
        if holding {
            until = Date() + Self.lasts
            unplaced = true
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
        witnesses = row.map { kept in chained(to: kept).merging(built.filter { $0.key != kept.id }) { $1 } } ?? [:]
        unplaced = row != nil
        // Its frames at the old width are guesses too (another row's frame still at the old
        // width can come after this one's at the new width).
        stale = row?.place.width
        return .hold(.offset(offset))
    }

    /// The row kept's width when the view's width changed (it's kept, or the width changed again
    /// with it kept). Until the row is laid out at another width, its frames are the lazy
    /// stack's guesses (other rows' frames at either width come between, so the width last seen
    /// doesn't tell).
    private var stale: CGFloat?

    /// The rows' ids, in order (`TranscriptStore.sections`).
    var order: (() -> [String])?
    /// Each row's height as last laid out.
    private var heights: [String: CGFloat] = [:]
    /// The rows' width as the view's width last changed: frames still at it are guesses.
    private var before: CGFloat?

    /// Where the rows next to the row kept were at the old width, one after another from it, as
    /// far as their heights are known (built then or not): when it leaves the built rows before
    /// it's laid out at the new width (a lazy stack laying the rows above out by new estimates
    /// can move the content under the view), they say where it went.
    private func chained(to kept: (id: String, place: CGRect, share: CGFloat, offset: CGFloat)) -> [String: CGRect] {
        guard let ids = order?(), let at = ids.firstIndex(of: kept.id) else { return [:] }
        var found: [String: CGRect] = [:]
        var y = kept.place.maxY
        for id in ids[(at + 1)...] {
            guard let height = heights[id] else { break }
            found[id] = CGRect(x: kept.place.minX, y: y, width: kept.place.width, height: height)
            y += height
        }
        y = kept.place.minY
        for id in ids[..<at].reversed() {
            guard let height = heights[id] else { break }
            y -= height
            found[id] = CGRect(x: kept.place.minX, y: y, width: kept.place.width, height: height)
        }
        return found
    }

    /// The view's own width changed.
    func resized() {
        before = width
        guard holding, let row, let place = places[row.id] else { return }
        stale = place.width
        until = max(until, Date() + Self.lasts)
    }

    /// A row's height as last laid out.
    func height(of id: String) -> CGFloat? { places[id]?.height }

    /// The built row at `y` in the content (or the first below it), and its top from `y`: what the
    /// reader sees at the top of the view, for the scroll log.
    func anchor(at y: CGFloat) -> (id: String, y: CGFloat)? {
        let row = places.first { $0.value.minY <= y && $0.value.maxY > y } ?? places.filter { $0.value.minY > y }.min { $0.value.minY < $1.value.minY }
        return row.map { ($0.key, $0.value.minY - y) }
    }

    /// No built row reaches below `y` in the content.
    func rowsEnd(above y: CGFloat) -> Bool { places.values.allSatisfy { $0.maxY <= y } }

    /// The reader scrolled, or the view keeps its place another way: nothing is held.
    func drop() {
        stale = nil
        before = nil
        row = nil
        endSince = nil
        unplaced = false
        seeking = nil
        witnesses = [:]
    }

    /// A scroll view built anew lays its rows out afresh: none of it is a new width.
    func reset() {
        stale = nil
        before = nil
        heights = [:]
        row = nil
        endSince = nil
        unplaced = false
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
            // A pinch magnifies the page and all that's in it; the pinned message stays its size
            // by being outside it for as long as the page is larger.
            content.overlay(alignment: .top) {
                MagnifiedBand(magnified: tracker.magnified, sections: sections, reveal: reveal, tracker: tracker)
            }
        }
    }

    private struct MagnifiedBand: View {
        let magnified: PageMagnified
        let sections: [TranscriptStore.SectionModel]
        let reveal: TranscriptActions
        let tracker: StickyTracker

        var body: some View {
            if magnified.on { Band(sections: sections, reveal: reveal, tracker: tracker) }
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
                StickyMessage(entry: header, open: open, actions: reveal, tracker: sticky, magnified: sticky.magnified).equatable()
            }
        }
    }
}

