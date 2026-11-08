import Foundation
import KoreCore
import LinkProtocol
import src

// Sync level 2, "Files + chats": a synced folder's box chats show on this Mac too, as read-only
// mirrors that follow them slowly. A mirror is this Mac's copy of the chat's event log (the same
// copy a box window shows first, `HostCache.events`), brought up to date in batches: every
// `every` (2 min) while the chat is running, once at each turn's end so an idle mirror is whole,
// and once when the mirror starts. Nothing runs for an idle chat, and nothing for a chat whose
// tab follows it live already (its copy keeps up by itself). A batch is the link's own catch-up
// (`chat.follow` from the copy's last seq, then `chat.unfollow`), so it rides the link's stream
// queue behind every interactive message. Continue here takes one last batch first (`catchUp`).

/// What a mirror needs of a box's link (tests: a stand-in).
@MainActor
package protocol MirrorLink: AnyObject {
    /// The chats the box has open in a folder, as it last said.
    func chats(in folder: String) -> [ChatMeta]
    /// A tab follows the chat live now.
    func isFollowed(_ chatId: String) -> Bool
    /// One batch: the chat's events since this Mac's copy, into the copy. False when the box
    /// couldn't be asked (offline, refused).
    func fetch(_ chatId: String) async -> Bool
    func onChatMeta(_ key: String, _ action: (@MainActor ([String]) -> Void)?)
}

/// The batches for one synced folder's box chats, while its sync runs.
@MainActor
package final class ChatMirrorBatches {
    /// How often a running chat's mirror catches up.
    package static let every: Duration = .seconds(120)

    package let folder: String
    private let link: any MirrorLink
    /// Whether a box chat syncs (its own toggle, else the folder's level).
    private let synced: @MainActor (String) -> Bool
    private let key: String
    /// The 2-minute loop of each running chat.
    private var loops: [String: Task<Void, Never>] = [:]
    private var fetching: [String: Task<Bool, Never>] = [:]
    private var started = false
    /// Waits between a running chat's batches (tests: a clock of their own).
    package var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Batches taken, by chat (tests), and when each chat's mirror last caught up.
    package private(set) var batches: [String: Int] = [:]
    package private(set) var caughtUp: [String: Date] = [:]
    /// Told after each batch (the mirror tabs read their copy again).
    package var onBatch: (@MainActor (String) -> Void)?

    package init(link: any MirrorLink, folder: String, synced: @escaping @MainActor (String) -> Bool) {
        self.link = link
        self.folder = folder
        self.synced = synced
        key = "mirror:" + folder
    }

    /// Mirrors start: each synced chat catches up once, running ones keep catching up.
    package func start() {
        guard !started else { return }
        started = true
        link.onChatMeta(key) { [weak self] ids in self?.heard(ids) }
        let chats = link.chats(in: folder)
        heard(chats.map(\.id))
        for meta in chats where mirrored(meta) && !meta.running { batch(meta.id) }
    }

    package func stop() {
        guard started else { return }
        started = false
        link.onChatMeta(key, nil)
        for loop in loops.values { loop.cancel() }
        loops = [:]
    }

    /// The running chats keep their loops; one that just ended its turn takes one batch.
    package func heard(_ ids: [String]) {
        guard started else { return }
        let chats = Dictionary(link.chats(in: folder).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for id in ids {
            guard let meta = chats[id], mirrored(meta) else {
                loops.removeValue(forKey: id)?.cancel()
                continue
            }
            if meta.running {
                if loops[id] == nil { loops[id] = loop(id) }
            } else if let loop = loops.removeValue(forKey: id) {
                loop.cancel()
                batch(id)
            }
        }
        // Chats the box no longer lists here.
        for id in loops.keys where chats[id] == nil { loops.removeValue(forKey: id)?.cancel() }
    }

    /// A chat's toggle or the folder's level changed: the chats are looked at again.
    package func refresh() {
        let chats = link.chats(in: folder)
        heard(chats.map(\.id))
        for meta in chats where mirrored(meta) && caughtUp[meta.id] == nil && !meta.running { batch(meta.id) }
    }

    /// Mirrored: synced, said something (following a fresh chat would start its CLI on the box),
    /// and living on the box (a chat a Mac holds mirrors from there).
    private func mirrored(_ meta: ChatMeta) -> Bool {
        guard synced(meta.id), meta.last != nil || meta.running else { return false }
        return meta.owner.map { $0.host == ChatOwner.box } ?? true
    }

    /// Running loops (tests).
    package var looping: Set<String> { Set(loops.keys) }

    private func loop(_ id: String) -> Task<Void, Never> {
        let sleep = sleep
        return Task { [weak self] in
            while !Task.isCancelled {
                await sleep(Self.every)
                guard !Task.isCancelled, let self else { return }
                _ = await self.fetch(id)
            }
        }
    }

    private func batch(_ id: String) {
        Task { _ = await fetch(id) }
    }

    /// Continue here: the mirror's last batch, now. True once the copy holds what the box has.
    @discardableResult
    package func catchUp(_ id: String) async -> Bool { await fetch(id) }

    private func fetch(_ id: String) async -> Bool {
        if let running = fetching[id] { return await running.value }
        // A tab following it live keeps the copy whole already.
        if link.isFollowed(id) {
            caughtUp[id] = Date()
            return true
        }
        let link = link
        let task = Task { await link.fetch(id) }
        fetching[id] = task
        let ok = await task.value
        fetching[id] = nil
        if ok {
            batches[id, default: 0] += 1
            caughtUp[id] = Date()
            onBatch?(id)
        }
        return ok
    }
}

// MARK: - The link's batch

extension HostConnection: MirrorLink {
    /// One batch: follows the chat from this Mac's copy's last seq until the box has said what
    /// came since (no frame for `quiet` after one, or none at all within `patience`), then stops.
    package func fetch(_ chatId: String) async -> Bool {
        guard isOnline, streams, !isFollowed(chatId) else { return isFollowed(chatId) }
        let cache = cache
        let copy = await Task.detached(priority: .utility) { cache.events(chat: chatId) }.value
        let batch = MirrorBatch(chatId: chatId, cache: cache, log: copy.log, seq: copy.items.last?.s)
        follow(batch)
        let done = await batch.settled(quiet: MirrorBatch.quiet, patience: MirrorBatch.patience)
        unfollow(batch)
        return done
    }
}

/// One mirror batch's follower: what the box sends goes into the copy, nothing is shown.
@MainActor
final class MirrorBatch: HostFollower {
    static let quiet: Duration = .milliseconds(500)
    static let patience: Duration = .seconds(10)

    let chatId: String?
    private let cache: HostCache
    private var log: String?
    private var seq: Int?
    private var heard = 0
    private var refusedNow = false
    private var gone = false

    init(chatId: String, cache: HostCache, log: String?, seq: Int?) {
        self.chatId = chatId
        self.cache = cache
        self.log = log
        self.seq = seq
    }

    var following: ChatFollow? { chatId.map { ChatFollow(chatId: $0, after: seq, log: log) } }

    func streamed(_ frame: ChatEvents) {
        guard let chatId else { return }
        heard += 1
        if frame.reset == true {
            log = frame.log
            seq = frame.seq ?? seq
            cache.restart(log: frame.log, items: frame.items, chat: chatId)
            return
        }
        guard frame.log == log else { return }
        let items = seq.map { last in frame.items.filter { $0.s > last } } ?? frame.items
        guard let last = items.last?.s else { return }
        seq = last
        cache.append(items, chat: chatId)
    }

    func refused(_ message: String) { refusedNow = true }
    func meta(_ meta: ChatMeta?) { if meta == nil { gone = true } }
    func linked(_ up: Bool) { if !up { refusedNow = true } }

    /// Waits for the box's answer: done once frames stop coming, false when refused or offline.
    func settled(quiet: Duration, patience: Duration) async -> Bool {
        let step: Duration = .milliseconds(50)
        var waited: Duration = .zero, still: Duration = .zero, last = 0
        while waited < patience {
            if refusedNow || gone { return false }
            try? await Task.sleep(for: step)
            waited += step
            if heard != last {
                last = heard
                still = .zero
            } else if heard > 0 {
                still += step
                if still >= quiet { return true }
            }
        }
        // Nothing came in all that time: the copy holds everything already.
        return !refusedNow
    }
}
