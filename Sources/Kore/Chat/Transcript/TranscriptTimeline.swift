import SwiftUI

/// The conversation as a timeline (look.md §2). Sections start at each user message, whose box
/// sticks to the top while its section scrolls by. Rows are built lazily and compare by value.
/// While the reader is at the end it follows new rows; after scrolling up nothing moves, and a
/// turn folding above the answer keeps the answer where it was.
struct TranscriptTimeline: View {
    let store: TranscriptStore
    var actions: TranscriptActions
    @Environment(\.chatColumn) private var column
    @StateObject private var following = Local(true)
    /// Written by the scroll view as the reader scrolls; held without re-rendering. `nudge`
    /// re-renders once, when the position has to be pushed back (after a fold).
    @StateObject private var position = Held(ScrollPosition(edge: .bottom))
    @StateObject private var nudge = Local(0)
    /// The last content height and offset, to undo a fold's shrink above the reader.
    @StateObject private var geometry = Held((height: CGFloat(0), offset: CGFloat(0)))
    @StateObject private var pendingFold = Held(false)

    private static let end = "transcript-end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                TimelineRow(item: item, actions: actions).equatable()
                            }
                        } header: {
                            if let header = section.header {
                                MessageHeader(entry: header, actions: reveal(proxy))
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
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentSize.height, $0.contentOffset.y] } action: { _, new in
                let (height, offset) = (new[0], new[1])
                if pendingFold.value, !following.value, height < geometry.value.height {
                    // The fold took height from above the answer: scroll up by as much.
                    pendingFold.value = false
                    let target = max(0, geometry.value.offset - (geometry.value.height - height))
                    position.value.scrollTo(y: target)
                    geometry.value = (height, target)
                    nudge.value &+= 1
                    return
                }
                geometry.value = (height, offset)
            }
            .onChange(of: store.folded?.seq) { pendingFold.value = true }
            .onChange(of: store.tail, initial: true) {
                if following.value { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
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
