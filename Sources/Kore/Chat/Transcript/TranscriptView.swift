import SwiftUI

/// The conversation. Rows are built lazily (only those on screen), and each row re-renders
/// only when its own entry changes. While the reader is at the end it stays there as rows
/// arrive and the last one streams; after scrolling up, nothing moves.
struct TranscriptView: View {
    let chat: ChatModel
    let openImage: (Attachment) -> Void
    @Environment(\.chatColumn) private var column
    /// Following the end. Only the reader's own scrolling changes it: content growing below
    /// the fold (a streaming reply) must not count as "scrolled away".
    @StateObject private var following = Local(true)

    private static let end = "transcript-end"

    /// Changes whenever the bottom of the transcript moves: a new row, or the last row growing.
    private var tail: [Int] {
        let last = chat.entries.last
        return [chat.entries.count, last?.text.utf8.count ?? 0, last?.result?.utf8.count ?? 0]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.entries) { entry in
                        EntryView(entry: entry, openImage: openImage).equatable()
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, column.padding)
                .padding(.vertical, 20)
                .frame(maxWidth: column.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // A short chat sits at the bottom, by the composer. (A plain bottom anchor for every
            // role left a long, lazily built transcript blank.)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                if new == .interacting {
                    following.value = false
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                }
            }
            .onChange(of: tail, initial: true) {
                if following.value { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }
}

extension EntryView: Equatable {
    /// `openImage` is the same action for every row, so content decides.
    nonisolated static func == (a: EntryView, b: EntryView) -> Bool { a.entry == b.entry }
}

extension ChatModel.Entry: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.kind == b.kind && a.text == b.text && a.result == b.result && a.done == b.done
            && a.isError == b.isError && a.toolName == b.toolName && a.from == b.from
            && a.attachments.map(\.id) == b.attachments.map(\.id)
    }
}
