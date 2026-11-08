import Foundation
import KoreCore
import LinkProtocol
import src

/// Link 1.10: while this Mac holds a box chat, its new events go to the box's replica
/// (`chat.mirror`), so the box window and the box's other clients follow it live, read-only.
/// Best effort, and cheap:
/// - a streamed answer's pieces are merged in memory and go at most every `every` seconds (or once
///   `held` bytes wait), so a chatty chat sends a few small frames, never a piece at a time;
/// - what's gathered is kept on disk (`<hosts>/<alias>/moves/<box chat>.mirror.jsonl`), one event a
///   line, and read back a frame at a time from what the replica holds (`owner.mirrored`): a
///   link that drops loses nothing, and memory holds only what waits to be written;
/// - nothing goes while no client follows the replica (`owner.followed`) or the link is down;
///   it catches up from the replica's count when one does.
@MainActor
package final class ChatMirrors {
    package static let shared = ChatMirrors()
    /// The live link to a box, when there is one: a mirror never dials.
    package var connection: (String) -> HostConnection? = { HostConnection.live($0) }
    package var store: MovedChats = .shared
    /// How often gathered events are written and sent at most, and how much waits before they go anyway.
    package var every: TimeInterval = 2
    package static let held = 64 * 1024
    private var mirrors: [String: ChatMirror] = [:]
    private var watched: Set<String> = []

    package init() {}

    /// One of a chat's events (its services' tap). Only a chat this Mac holds for a box is mirrored.
    package func event(session: String?, _ event: ChatEvent) {
        guard let session, let moved = store.session(session) else { return }
        mirror(moved).take(event)
    }

    /// The mirror of a moved chat, made the first time it's needed.
    package func mirror(_ moved: MovedChat) -> ChatMirror {
        if let mirror = mirrors[moved.session], mirror.moved.gen == moved.gen { return mirror }
        let mirror = ChatMirror(moved: moved, owner: self)
        mirrors[moved.session] = mirror
        return mirror
    }

    /// Everything gathered for a chat, written: the Mac's count, which a return says (`seq`), so
    /// the box knows whether its replica holds it all.
    package func count(_ moved: MovedChat) -> Int {
        let mirror = mirror(moved)
        mirror.write()
        return mirror.count
    }

    /// The chat went back (or away): its mirror and its file go.
    package func ended(session: String) {
        mirrors.removeValue(forKey: session)?.finish()
    }

    /// The link to `alias`, watched once: a replica followed again, or the link back, sends what's due.
    func watch(_ connection: HostConnection) {
        guard watched.insert(connection.alias).inserted else { return }
        let alias = connection.alias
        connection.onChatMeta("mirror") { [weak self] ids in
            guard let self else { return }
            for mirror in self.mirrors.values where mirror.moved.alias == alias && ids.contains(mirror.moved.boxChat) { mirror.push() }
        }
    }
}

@MainActor
package final class ChatMirror {
    package private(set) var moved: MovedChat
    private unowned let owner: ChatMirrors
    let file: URL
    /// Where each written event's line starts, and how many there are: the Mac's count.
    private var offsets: [UInt64] = []
    private var end: UInt64 = 0
    /// Events gathered since the last write, merged.
    private var pending: [ChatEvent] = []
    private var pendingBytes = 0
    private var armed = false
    private var sending = false
    /// What the replica holds, as the box last said.
    package private(set) var acked: Int
    /// Bytes `chat.mirror` put on the link so far, and frames (a test's and the log's measure).
    package private(set) var sentBytes = 0
    package private(set) var frames = 0

    init(moved: MovedChat, owner: ChatMirrors) {
        self.moved = moved
        self.owner = owner
        acked = moved.mirrored ?? 0
        let folder = HostCache(alias: moved.alias, root: owner.store.root).folder.appendingPathComponent("moves", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent(HostCache.safe(moved.boxChat) + ".mirror.jsonl")
        index()
    }

    package var count: Int { offsets.count }

    /// The file's lines, read once at start (a Kore that quit while holding the chat), a piece at a time.
    private func index() {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            return
        }
        defer { try? handle.close() }
        var at: UInt64 = 0
        var lineStart: UInt64 = 0
        while let piece = try? handle.read(upToCount: 256 * 1024), !piece.isEmpty {
            for (i, byte) in piece.enumerated() where byte == 0x0A {
                offsets.append(lineStart)
                lineStart = at + UInt64(i) + 1
            }
            at += UInt64(piece.count)
        }
        end = lineStart
        // A torn last line (a crash mid-write) is cut off.
        if at != lineStart, let writer = try? FileHandle(forWritingTo: file) {
            try? writer.truncate(atOffset: lineStart)
            try? writer.close()
        }
    }

    /// One event of the chat: a history read in is the CLI's own and isn't mirrored.
    func take(_ event: ChatEvent) {
        switch event {
        case .replayed, .historyReplaced, .earlierHistory: return
        default: break
        }
        if let last = pending.last, let merged = Self.merged(last, event) {
            pending[pending.count - 1] = merged
        } else {
            pending.append(event)
        }
        pendingBytes += Self.size(event)
        if pendingBytes >= ChatMirrors.held { return write() }
        guard !armed else { return }
        armed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + owner.every) { [weak self] in
            MainActor.assumeIsolated {
                self?.armed = false
                self?.write()
            }
        }
    }

    /// A streamed piece onto the one before it, when they're the same stream.
    static func merged(_ a: ChatEvent, _ b: ChatEvent) -> ChatEvent? {
        // A merged piece stays well under a frame.
        guard size(a) + size(b) <= ChatMirrors.held else { return nil }
        switch (a, b) {
        case (.text(let id, let kind, let t1, let agent), .text(let id2, let kind2, let t2, let agent2)) where id == id2 && kind == kind2 && agent == agent2:
            return .text(id, kind, t1 + t2, agent: agent)
        case (.toolOutput(let id, let t1, let agent), .toolOutput(let id2, let t2, let agent2)) where id == id2 && agent == agent2:
            return .toolOutput(id: id, t1 + t2, agent: agent)
        case (.commandOutput(let id, let t1), .commandOutput(let id2, let t2)) where id == id2:
            return .commandOutput(id: id, t1 + t2)
        default:
            return nil
        }
    }

    private static func size(_ event: ChatEvent) -> Int {
        switch event {
        case .text(_, _, let text, _), .toolOutput(_, let text, _), .commandOutput(_, let text): text.utf8.count
        default: 256
        }
    }

    /// What's gathered goes to the file, then to the box when it's due.
    package func write() {
        guard !pending.isEmpty else { return push() }
        var data = Data()
        for event in pending {
            let line = StreamWire.encode(event)
            guard !line.isEmpty else { continue }
            offsets.append(end + UInt64(data.count))
            data.append(line)
            data.append(0x0A)
        }
        pending = []
        pendingBytes = 0
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
        end += UInt64(data.count)
        push()
    }

    /// Sends from what the replica holds, a frame at a time, while a client follows it and the
    /// link is up.
    package func push() {
        guard !sending, acked < count, let connection = owner.connection(moved.alias), connection.isOnline, connection.moves else { return }
        owner.watch(connection)
        guard connection.chats[moved.boxChat]?.owner?.followed == true else { return }
        let items = read(from: acked)
        guard !items.isEmpty else { return }
        sending = true
        let args = ControlArgs(chatId: moved.boxChat, gen: moved.gen, seq: acked, events: MirrorItems(items))
        Task {
            let result = await connection.move(.chatMirror, args)
            sending = false
            sentBytes += connection.lastMoveBytes
            frames += 1
            guard let now = result.mirrored else { return }
            // The box holds `now`: the next frame goes from there (a gap's answer says where too).
            let advanced = now != acked || result.ok
            acked = now
            owner.store.noteMirrored(moved.session, now)
            if advanced, acked < count { push() }
        }
    }

    /// Events from `start`, up to a frame's worth.
    private func read(from start: Int) -> [StreamItem] {
        guard start < offsets.count, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offsets[start])
        let last = min(offsets.count, start + LinkMoves.mirrorMax)
        let stop = last < offsets.count ? offsets[last] : end
        let want = Int(min(stop - offsets[start], UInt64(LinkMoves.mirrorBytes)))
        guard let data = try? handle.read(upToCount: max(want, 1)) else { return [] }
        var items: [StreamItem] = []
        var at = data.startIndex
        var seq = start
        while seq < last, let newline = data[at...].firstIndex(of: 0x0A) {
            let event = try? JSONDecoder().decode(ChatEvent.self, from: data[at..<newline])
            items.append(StreamItem(s: seq, e: event))
            at = newline + 1
            seq += 1
        }
        // One event past a frame's bytes (a huge tool result) is counted but not carried: the
        // box's frame can't hold it, and the replica is best effort.
        if items.isEmpty { items.append(StreamItem(s: start, e: nil)) }
        return items
    }

    func finish() {
        try? FileManager.default.removeItem(at: file)
    }
}
