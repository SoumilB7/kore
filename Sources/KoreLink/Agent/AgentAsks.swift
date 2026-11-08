import Foundation
import KoreUI
import LinkProtocol
import src

/// Chat to chat (the owner, 2026-11-17, `z-docs/design/arsenal-ask.html`): a chat at Act unlimited
/// asks another at Act unlimited a question (`chat.ask`). Kore holds it until that chat is idle
/// (never mid-turn), then sends it as that chat's next message, marked "From <asker> · Arsenal",
/// with a line only its agent reads saying how to answer (`chat.reply`). The answer goes back to
/// the asker as a line in its chat and to `chat.wait`. One hop: a chat answering an ask asks no
/// one; an ask ends after 30 minutes. Every step is one quiet line in the chats it touches.
@MainActor
package final class ArsenalAsks {
    package static let shared = ArsenalAsks()
    package static let lifetime: TimeInterval = 30 * 60
    package static let asksPerHour = 20
    package static let fetchesPerHour = 50
    /// A chat on a box reaching up into the Mac's files or chats: off unless the owner turns it on
    /// (`defaults write <Kore> arsenalBoxReachesMac -bool YES`).
    package static var boxReachesMac: Bool { UserDefaults.standard.bool(forKey: "arsenalBoxReachesMac") }

    /// The clock: tests move it.
    package var now: () -> Date = Date.init
    /// How often a held ask looks again for its chat to be idle.
    package var deliverEvery: Duration = .milliseconds(300)

    package enum End: Equatable, Sendable { case answered, expired, gone }

    package struct Ask: Equatable, Sendable {
        package let id: String
        package let asker: String
        package let target: String
        package let askerName: String
        package let targetName: String
        package let question: String
        package let created: Date
        package var delivered = false
        package var answer: String?
        /// Where the answer's file landed.
        package var file: String?
        package var ended: End?
        package var open: Bool { ended == nil }
    }

    package private(set) var asks: [String: Ask] = [:]
    private var askBudgets: [String: RateLimiter] = [:]
    private var fetchBudgets: [String: RateLimiter] = [:]
    private var waiters: [String: [@MainActor (Ask) -> Void]] = [:]
    private var delivering: Task<Void, Never>?

    package init() {}

    /// Everything forgotten (tests).
    package func reset() {
        asks = [:]
        askBudgets = [:]
        fetchBudgets = [:]
        waiters = [:]
        delivering?.cancel()
        delivering = nil
    }

    // MARK: Rules

    /// The ask `chat` is answering: on its way to it or delivered, not answered or ended yet.
    package func answering(_ chat: String) -> Ask? {
        expireDue()
        return asks.values.filter { $0.target == chat && $0.open }.min { $0.created < $1.created }
    }

    /// Why `asker` can't ask `target` now (after "Not asked: "); nil when it can. Both chats at Act
    /// unlimited, never itself, never while it's answering an ask (one hop), 20 an hour.
    package func askRefusal(asker: String, target: String, targetName: String, targetTier: AgentTier) -> String? {
        if asker == target { return "a chat doesn't ask itself" }
        if let open = answering(asker) { return "this chat is answering \(open.askerName)'s ask, so it asks no one until it has (one hop)" }
        if targetTier < .drive { return "\(targetName) isn't Act unlimited" }
        if let free = askBudgets[asker]?.nextFree(at: now()) {
            return "\(Self.asksPerHour) asks an hour at most: " + AgentChannel.freesUp(free, now: now())
        }
        return nil
    }

    /// Why `chat` can't answer ask `id` (after "Not answered: "); nil when it can.
    package func replyRefusal(_ id: String, from chat: String) -> String? {
        expireDue()
        guard let ask = asks[id] else { return "no ask has the id \u{201C}\(id.prefix(40))\u{201D}" }
        guard ask.target == chat else { return "that ask is to another chat" }
        switch ask.ended {
        case .answered: return "that ask was answered already"
        case .expired: return "that ask expired (\(Int(Self.lifetime / 60)) min)"
        case .gone: return "\(ask.askerName) is closed"
        case nil: return nil
        }
    }

    /// Why `chat` can't fetch now (after "Not fetched: "); nil when it can.
    package func fetchRefusal(_ chat: String) -> String? {
        guard let free = fetchBudgets[chat]?.nextFree(at: now()) else { return nil }
        return "\(Self.fetchesPerHour) fetches an hour at most: " + AgentChannel.freesUp(free, now: now())
    }

    package func spentFetch(_ chat: String) {
        _ = fetchBudgets[chat, default: RateLimiter(limit: Self.fetchesPerHour, per: 3600)].take(at: now())
    }

    // MARK: Its life

    /// A new ask, one of the asker's spent.
    @discardableResult
    package func open(asker: String, askerName: String, target: String, targetName: String, question: String) -> Ask {
        var id = Self.newId()
        while asks[id] != nil { id = Self.newId() }
        let ask = Ask(id: id, asker: asker, target: target, askerName: askerName, targetName: targetName, question: question, created: now())
        asks[id] = ask
        _ = askBudgets[asker, default: RateLimiter(limit: Self.asksPerHour, per: 3600)].take(at: now())
        return ask
    }

    package func delivered(_ id: String) { asks[id]?.delivered = true }

    /// The answer in: the ask ends, its waiters are told.
    @discardableResult
    package func answer(_ id: String, text: String, file: String?) -> Ask? {
        guard var ask = asks[id], ask.open else { return nil }
        ask.answer = text
        ask.file = file
        ask.ended = .answered
        asks[id] = ask
        tell(ask)
        return ask
    }

    /// The chat it was for closed before it got there.
    package func gone(_ id: String) {
        guard var ask = asks[id], ask.open else { return }
        ask.ended = .gone
        asks[id] = ask
        tell(ask)
    }

    /// Asks past their 30 minutes end, their waiters told; long-ended ones are let go.
    @discardableResult
    package func expireDue() -> [Ask] {
        let now = now()
        var ended: [Ask] = []
        for (id, var ask) in asks {
            if ask.open, now.timeIntervalSince(ask.created) >= Self.lifetime {
                ask.ended = .expired
                asks[id] = ask
                ended.append(ask)
            } else if !ask.open, now.timeIntervalSince(ask.created) >= 4 * Self.lifetime {
                asks[id] = nil
            }
        }
        for ask in ended { tell(ask) }
        return ended
    }

    /// `done` once the ask ends (now, when it has).
    package func whenEnded(_ id: String, _ done: @escaping @MainActor (Ask) -> Void) {
        expireDue()
        guard let ask = asks[id] else { return }
        if ask.open { waiters[id, default: []].append(done) } else { done(ask) }
    }

    private func tell(_ ask: Ask) {
        for waiter in waiters.removeValue(forKey: ask.id) ?? [] { waiter(ask) }
    }

    private static func newId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }

    // MARK: In the chats

    /// The line the asked chat's agent reads with the question, and only there.
    static func note(_ ask: Ask, askerShort: String) -> String {
        "Kore note: the message after this is an Arsenal ask from the chat “\(ask.askerName)” (\(askerShort)), ask \(ask.id). "
            + "Answer it with kore_reply (ask \(ask.id), your answer as text, and path: a file in this chat's folder if one helps); "
            + "the answer goes back to that chat. Until you answer, this chat can't ask another chat (one hop). "
            + "It expires \(Int(Self.lifetime / 60)) minutes after it was asked."
    }

    /// One line of a question or an answer, for a transcript line.
    static func line(_ text: String, max: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Opens an ask from `asker` to `target`, its line in the asker's chat, and sends it once
    /// `target` is idle.
    package func ask(_ asker: Chat, _ target: Chat, question: String) -> Ask {
        let ask = open(
            asker: asker.id.uuidString, askerName: AgentReads.title(asker.title), target: target.id.uuidString,
            targetName: AgentReads.title(target.title), question: question)
        asker.note("→ Asked \(ask.targetName): \(Self.line(question))")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime + 1) { [weak self] in
            MainActor.assumeIsolated { self?.expireNoticed() }
        }
        deliverHeld()
        return ask
    }

    /// Held asks go to their chats once each is idle: no turn, nothing queued, nothing waiting
    /// for the network. One look now, then every `deliverEvery` while any is held.
    package func deliverHeld() {
        expireNoticed()
        let held = asks.values.filter { $0.open && !$0.delivered }.sorted { $0.created < $1.created }
        guard !held.isEmpty else {
            delivering?.cancel()
            delivering = nil
            return
        }
        let chats = AgentReads.chatsByID()
        var busy = Set<String>()
        for ask in held {
            guard let target = chats[ask.target] else {
                gone(ask.id)
                chats[ask.asker]?.note("⊘ No answer: \(ask.targetName) closed before the ask reached it")
                continue
            }
            guard !busy.contains(ask.target), !target.isBusy, target.queuedCount == 0, !target.isWaitingForNetwork else {
                busy.insert(ask.target)
                continue
            }
            target.note("From \(ask.askerName) · Arsenal")
            if target.sendFromLink(ask.question, note: Self.note(ask, askerShort: AgentReads.short(ask.asker))) {
                delivered(ask.id)
            }
            // One at a time to a chat: the next waits for this one's turn.
            busy.insert(ask.target)
        }
        guard delivering == nil, asks.values.contains(where: { $0.open && !$0.delivered }) else { return }
        delivering = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.deliverEvery)
                guard !Task.isCancelled else { return }
                self.delivering = nil
                self.deliverHeld()
                if self.delivering == nil || !self.asks.values.contains(where: { $0.open && !$0.delivered }) { return }
            }
        }
    }

    /// Asks that just ran out: a line in each asker's chat.
    private func expireNoticed() {
        let chats = AgentReads.chatsByID()
        for ask in expireDue() {
            chats[ask.asker]?.note("⊘ No answer from \(ask.targetName) in \(Int(Self.lifetime / 60)) min")
        }
    }

    /// The answer's lines: under the asker's, with its file; the answering chat's own.
    package func answered(_ ask: Ask, file: FileName? = nil) {
        let chats = AgentReads.chatsByID()
        let with = file.map { ", with \($0.name) → \($0.where)" } ?? ""
        chats[ask.asker]?.note("← \(ask.targetName) answered\(with)\n\(ask.answer ?? "")")
        chats[ask.target]?.note("→ Answered \(ask.askerName)" + (file.map { ", with \($0.name)" } ?? ""))
    }

    /// A file as a line names it: its name, and where it landed in the asker's folder.
    package struct FileName: Sendable {
        package let name: String
        package let `where`: String
        package init(name: String, where place: String) {
            self.name = name
            self.where = place
        }
    }
}
