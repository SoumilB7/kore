import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// One proven client of Kore's link, the doorbell's companion or a phone over KoreNet: what it
/// follows (its `LinkFeed.Client`), its limits and uploads, and the handling of what it sends.
/// The doorbell's companion acts under the run's control (standard or full); a phone asks
/// (`LinkAsk`): it reads, sends within a chat's mode and arranges, and raises only with its
/// fingerprint (`PhoneLink`).
@MainActor
final class LinkPeer {
    enum Grant: Equatable {
        /// The doorbell's companion, as its card allowed it this run.
        case companion(LinkControlLevel)
        /// A phone (read + ask).
        case phone
    }

    let grant: Grant
    let feed: LinkFeed
    let client: LinkFeed.Client
    /// What it did, for the mark's recent lines (action and chat title, never text).
    var did: (String) -> Void = { _ in }
    /// The client is too fast: the link ends with this reason.
    var ends: (LinkMessage.ByeReason) -> Void = { _ in }
    /// Who the log says acted (an opaque id).
    var who: String?

    var bucket = MessageBucket()
    var commands = RateLimiter(limit: 30, per: 60)
    var sends = RateLimiter(limit: 10, per: 60)
    /// `account.*`: ten a minute.
    var accounts = RateLimiter(limit: 10, per: 60)
    /// History pages, two a second.
    var reads = RateLimiter(limit: 2, per: 1)
    /// Files on their way in, and finished ones waiting for a send (by blob id, kept 10 min).
    var uploads = LinkUploads()
    var blobs: [String: (url: URL, made: Date)] = [:]

    init(grant: Grant, feed: LinkFeed, client: LinkFeed.Client) {
        self.grant = grant
        self.feed = feed
        self.client = client
    }

    var full: Bool { grant == .companion(.full) }
    var phone: Bool { grant == .phone }
    /// History, diffs and earlier turns: full control, or a phone's read.
    var reads1_2: Bool { full || phone }

    func send(_ message: LinkMessage) { client.sink.send(message) }

    /// Frames as they came: rate-limited (uploads' chunks are bounded by the upload), then handled.
    func received(_ message: LinkMessage) {
        // An upload's chunks are bounded by the upload itself (its declared size), not counted
        // as messages: a 12 MB photo is 256 of them.
        if case .blobPutChunk = message { return handle(message) }
        switch bucket.take() {
        case .ok: break
        case .over:
            if case .cmd(let id, _) = message { send(.result(.init(id: id, ok: false, code: .rateLimited))) }
            return
        case .far:
            return ends(.rateLimited)
        }
        handle(message)
    }

    private func handle(_ message: LinkMessage) {
        switch message {
        case .txOpen(let chatId, let last):
            guard let chat = LinkSnapshot.chatsByID()[chatId] else {
                send(.result(.init(id: "tx.open:" + chatId, ok: false, code: .goneChat, message: "That chat isn't open in Kore any more.")))
                return
            }
            // A chat no tab has shown yet (restored, or opened from the link): it starts in the
            // background, as its tab would, and its page follows as its history arrives.
            if !chat.hasStarted { wake(chat, chatId) }
            feed.follow(client, chatId, last: last)
        case .txMore(let chatId, let count):
            feed.more(client, chatId, count: count)
        case .txClose(let chatId):
            feed.unfollow(client, chatId)
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            let entry = LinkSnapshot.chatsByID()[chatId]?.transcript.entries.first { $0.id.uuidString == entryId }
            let text: String =
                switch field {
                case .text: entry?.text ?? ""
                case .input: entry?.input ?? ""
                case .result: entry?.result ?? ""
                case .unknown: ""
                }
            let piece = LinkSnapshot.piece(text, from: offset)
            send(.entryChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
        case .cardMore(let id, let chatId, let cardId, let offset):
            let approval = LinkSnapshot.chatsByID()[chatId]?.approvals.pending.first { $0.id == cardId }
            let piece = LinkSnapshot.piece(approval.flatMap(LinkSnapshot.fullContent) ?? "", from: offset)
            send(.cardChunk(id: id, text: piece.text, offset: piece.offset, total: piece.total))
        case .blobPutBegin(let uploadId, let name, let mime, let size, let sha256):
            sweepBlobs()
            if let failure = uploads.begin(uploadId, name: name, mime: mime, size: size, sha256: sha256) { failed(uploadId, failure) }
        case .blobPutChunk(let uploadId, let index, let data):
            if let failure = uploads.chunk(uploadId, index: index, base64: data) { failed(uploadId, failure) }
        case .blobPutEnd(let uploadId):
            switch uploads.end(uploadId) {
            case .failure(let failure): failed(uploadId, failure)
            case .success(let file):
                guard blobs.count < LinkPolicy.maxBlobs * 2, let url = LinkFiles.save(file) else {
                    return failed(uploadId, .init(.busy, "Kore couldn't keep the file."))
                }
                let blobId = UUID().uuidString
                blobs[blobId] = (url, Date())
                UILog.event("link-blob", ["kind": "\(file.sniffed)", "bytes": "\(file.data.count)"])
                send(.result(.init(id: "blob.put:" + uploadId, ok: true, blobId: blobId)))
            }
        case .blobGet(let id, let chatId, let ref, let variant, let offset):
            guard let chat = LinkSnapshot.chatsByID()[chatId] else {
                return send(.result(.init(id: id, ok: false, code: .goneChat, message: "That chat isn't open in Kore any more.")))
            }
            switch LinkFiles.read(chat, ref: ref, variant: variant) {
            case .failure(let failure): send(.result(.init(id: id, ok: false, code: failure.code, message: failure.message)))
            case .success(let file):
                let start = min(max(offset, 0), file.data.count)
                let piece = file.data[file.data.startIndex + start..<file.data.startIndex + min(start + LinkFiles.piece, file.data.count)]
                send(.blobChunk(id: id, mime: file.mime, offset: start, total: file.data.count, data: Data(piece).base64EncodedString()))
            }
        case .cmd(let id, .control(let kind, let args)):
            performControl(id, kind, args)
        case .cmd(let id, let command):
            send(.result(perform(id, command)))
            feed.poke()
        case .txEarlier(let chatId):
            guard reads1_2 else { return send(.result(.init(id: "tx.earlier:" + chatId, ok: false, code: .deniedControl))) }
            guard let chat = LinkSnapshot.chatsByID()[chatId], client.subs[chatId] != nil else {
                return send(.result(.init(id: "tx.earlier:" + chatId, ok: false, code: .goneChat, message: "Follow that chat first.")))
            }
            // The earlier turns arrive in its transcript; the next tick sends them as a delta.
            chat.linkLoadEarlier()
        case .historyList(let id, let windowId, let query, let archived, let offset):
            guard reads1_2 else { return send(.result(.init(id: "history.list:" + id, ok: false, code: .deniedControl))) }
            guard reads.take() else { return send(.result(.init(id: "history.list:" + id, ok: false, code: .rateLimited))) }
            guard let workspace = LinkSnapshot.workspaces().first(where: { LinkSnapshot.windowID($0) == windowId }) else {
                return send(.result(.init(id: "history.list:" + id, ok: false, code: .goneWindow)))
            }
            let (sessions, more) = LinkSnapshot.history(workspace, query: query, archived: archived, offset: offset)
            send(.historyPage(id: id, windowId: windowId, sessions: sessions, more: more))
        case .diffGet(let id, let chatId, let turnId, let path):
            guard reads1_2 else { return send(.result(.init(id: "diff.get:" + id, ok: false, code: .deniedControl))) }
            guard let chat = LinkSnapshot.chatsByID()[chatId] else { return send(.result(.init(id: "diff.get:" + id, ok: false, code: .goneChat))) }
            guard let change = chat.linkChanges(turn: turnId, path: path) else {
                return send(.result(.init(id: "diff.get:" + id, ok: false, code: .invalid, message: "That turn didn't change that file.")))
            }
            let (hunks, more) = LinkSnapshot.hunks(change)
            send(.diffHunks(id: id, path: path, hunks: hunks, more: more))
        case .presence(let onScreen, _):
            // Phones say it (1.12); the doorbell's companion always counts as looking, as it did.
            if phone { feed.presence(client, onScreen: onScreen) }
        case .bye, .challenge, .hello, .welcome, .command, .snapshot, .delta, .txPage, .txDelta, .txReset, .entryChunk, .cardChunk, .result,
            .attnState, .attnEvent, .blobChunk, .policy, .historyPage, .diffHunks, .unknown:
            // `bye` is the host's; the rest are Kore's own messages, or a type from a newer client.
            break
        }
    }

    /// Starts a chat the link opened before any tab showed it. A start that fails answers
    /// `gone.chat`, keyed `tx.open:<chatId>`.
    private func wake(_ chat: Chat, _ chatId: String) {
        UILog.event("link-wake-chat", ["chat": chatId])
        Task { [weak self] in
            await chat.startInBackground()
            guard let self, chat.attention == .failed else { return }
            self.send(.result(.init(id: "tx.open:" + chatId, ok: false, code: .goneChat, message: "Kore couldn't open that chat.")))
        }
    }

    /// An upload that failed: its result, keyed `blob.put:<uploadId>`.
    private func failed(_ uploadId: String, _ failure: LinkUploads.Failure) {
        send(.result(.init(id: "blob.put:" + uploadId, ok: false, code: failure.code, message: failure.message)))
    }

    /// Unfinished uploads and unsent blobs go after ten minutes, looked at as new ones come.
    private func sweepBlobs() {
        guard !blobs.isEmpty || uploads.count > 0 else { return }
        let now = Date()
        uploads.sweep(at: now)
        blobs = blobs.filter { now.timeIntervalSince($0.value.made) < 600 }
    }

    /// A plain command: under the companion's control, or ask's for a phone (a risky Allow has
    /// had its signature checked by then).
    func perform(_ id: String, _ command: LinkCommand, control: LinkControlLevel? = nil) -> LinkMessage.Result {
        guard commands.take() else { return .init(id: id, ok: false, code: .rateLimited) }
        if case .send = command, !sends.take() { return .init(id: id, ok: false, code: .rateLimited) }
        let chat = command.chatId.flatMap { LinkSnapshot.chatsByID()[$0] }
        var files: [URL] = []
        if case .send(_, _, let blobs) = command {
            files = blobs.compactMap { self.blobs[$0]?.url }
            guard files.count == blobs.count else { return .init(id: id, ok: false, code: .goneBlob, message: "A file wasn't uploaded, or expired.") }
        }
        let level: LinkControlLevel =
            switch grant {
            // The companion's plain commands have always been checked at standard (its full
            // control widens 1.2's commands); a phone's likewise, until a signed raise says more.
            case .companion: control ?? .standard
            case .phone: control ?? .standard
            }
        let outcome = LinkActions.apply(command, chat: chat, files: files, control: level)
        if outcome.ok, case .send(_, _, let blobs) = command { for blob in blobs { self.blobs[blob] = nil } }
        UILog.event("link-cmd", ["type": command.type, "chat": command.chatId, "code": outcome.code?.rawValue ?? "ok", "by": phone ? "phone" : nil])
        if outcome.ok { did(LinkHost.describe(command, chat: chat ?? outcome.newChat)) }
        return .init(
            id: id, ok: outcome.ok, code: outcome.code, message: outcome.message, chatId: outcome.newChat?.id.uuidString,
            windowId: outcome.newWindowId)
    }

    /// A 1.2 command: with full control, or within ask for a phone. Some wait (a fork, a history
    /// rename), so its result comes when it's done.
    func performControl(_ id: String, _ kind: ControlKind, _ args: ControlArgs, raised: Bool = false) {
        guard commands.take() else { return send(.result(.init(id: id, ok: false, code: .rateLimited))) }
        if kind.onAccount, !accounts.take() { return send(.result(.init(id: id, ok: false, code: .rateLimited))) }
        let control: LinkControlLevel
        switch grant {
        case .companion(let level):
            control = level
        case .phone:
            let chat = args.chatId.flatMap { LinkSnapshot.chatsByID()[$0] }
            if !raised, case .deny(let code, let message) = LinkAsk.check(kind, args, chat.map(LinkSnapshot.facts), arsenal: chat?.arsenal?.rawValue) {
                return send(.result(.init(id: id, ok: false, code: code, message: message)))
            }
            // Within ask (or raised by the fingerprint), checked as full control checks it.
            control = .full
        }
        var files: [URL] = []
        if kind == .chatSendAtReset, let blobs = args.blobs {
            files = blobs.compactMap { self.blobs[$0]?.url }
            guard files.count == blobs.count else { return send(.result(.init(id: id, ok: false, code: .goneBlob, message: "A file wasn't uploaded, or expired."))) }
        }
        Task { [weak self] in
            let outcome = await LinkControlActions.apply(kind, args, control: control, files: files)
            guard let self else { return }
            if outcome.ok, kind == .chatSendAtReset { for blob in args.blobs ?? [] { self.blobs[blob] = nil } }
            // An account command logs its CLI and login id only: never an email, code or page.
            UILog.event(
                "link-cmd",
                kind.onAccount
                    ? ["type": kind.rawValue, "cli": args.provider, "login": args.login, "code": outcome.code?.rawValue ?? "ok"]
                    : ["type": kind.rawValue, "chat": args.chatId, "code": outcome.code?.rawValue ?? "ok", "by": self.phone ? "phone" : nil])
            let chat = args.chatId.flatMap { LinkSnapshot.chatsByID()[$0] } ?? outcome.newChat
            if outcome.ok { self.did(LinkHost.describe(.control(kind, args), chat: chat)) }
            if kind == .chatSetArsenal || kind == .arsenalStopAll {
                UILog.event(
                    "link-arsenal",
                    [
                        "chat": kind == .arsenalStopAll ? "all" : String((args.chatId ?? "").prefix(8)),
                        "tier": kind == .arsenalStopAll ? "off" : args.tier, "by": self.who, "code": outcome.code?.rawValue ?? "ok",
                    ])
            }
            self.send(
                .result(
                    .init(
                        id: id, ok: outcome.ok, code: outcome.code, message: outcome.message, chatId: outcome.newChat?.id.uuidString,
                        windowId: outcome.newWindowId, tabId: outcome.newTabId)))
            self.feed.poke()
        }
    }
}
