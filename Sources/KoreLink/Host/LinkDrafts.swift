import Foundation
import KoreUI
import src

/// The Mac's drafts as the link sends them to a phone: each chat's composer text kept half a
/// second after typing stops, with a count that moves on each kept change (as a box's `draftRev`).
/// Typing on the Mac marks the chat; only the settled text redoes its meta, once.
@MainActor
final class LinkDrafts {
    /// How long typing rests before the draft is kept (tests set it).
    static var settle: TimeInterval = 0.5

    private var kept: [String: (text: String, rev: Int)] = [:]
    private var waiting: [String: Chat] = [:]
    private var timer: Timer?
    /// A chat's kept draft changed: its meta goes again.
    var changed: ((String) -> Void)?

    /// The draft a meta carries: the kept one, else the composer's now (nil count until it moves).
    func kept(_ chat: Chat, id: String) -> (text: String, rev: Int?) {
        if let made = kept[id] { return (made.text, made.rev) }
        return (chat.linkDraft, nil)
    }

    /// The composer changed: kept once typing rests.
    func typed(_ chat: Chat) {
        waiting[chat.id.uuidString] = chat
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.settle, repeats: false) { _ in MainActor.assumeIsolated { [weak self] in self?.keep() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Keeps what's waiting now (the timer, or a test).
    func keep() {
        timer?.invalidate()
        timer = nil
        let now = waiting
        waiting = [:]
        for (id, chat) in now {
            let text = chat.linkDraft
            if let had = kept[id], had.text == text { continue }
            kept[id] = (text, (kept[id]?.rev ?? 0) + 1)
            changed?(id)
        }
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        kept = [:]
        waiting = [:]
    }
}
