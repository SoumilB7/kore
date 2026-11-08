import AppKit
import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// One connection of an allowed companion (`LinkRun`): from a ring's reply until the client goes.
/// It holds the socket, the one client, and the title row's mark while connected; what the client
/// is sent comes from the shared `LinkFeed`, which serves phones over KoreNet too. Nothing of it
/// exists between connections, and ending it removes all of it (`z-docs/link-protocol.md`).
@MainActor
package final class LinkHost {
    /// The link awake now; nil while asleep.
    package private(set) static var current: LinkHost?

    /// How long a ring's socket waits for its client before it's removed.
    package static var connectWithin: TimeInterval = 30
    /// How long a new connection has to prove itself.
    static let helloWithin: TimeInterval = 10

    package let run: LinkRun
    package var name: String { run.name }
    package let socketPath: String
    /// This connection's own secret: a new one for every ring.
    package let secret: Data
    private let queue = DispatchQueue(label: "dev.kore.link")
    /// Where the client's batches are diffed and encoded, off the main actor.
    private let sinkQueue = DispatchQueue(label: "dev.kore.link.sink")
    private let listener: LinkListener
    private var mark: LinkMark { run.mark }
    private let feed: LinkFeed

    /// The client on the socket, proven or not yet.
    private var session: Session?
    /// How long each tick took (the last 2000), for the navigation budget.
    package var tickTimes: [Duration] { feed.tickTimes }

    /// One connection's state.
    private final class Session {
        let connection: LinkConnection
        let nonce = LinkProof.random(32)
        /// Once proven: what it follows and how its messages are handled.
        var peer: LinkPeer?
        var proven: Bool { peer != nil }

        init(connection: LinkConnection) { self.connection = connection }
    }

    // MARK: Waking and ending

    /// Wakes a connection for the allowed `run`: a socket, in its own directory, with a new secret.
    package static func wake(run: LinkRun, directory: URL = defaultDirectory) throws -> LinkHost {
        if let current { current.end(.disconnected) }
        let host = try LinkHost(run: run, directory: directory)
        current = host
        return host
    }

    /// Allows `name` for this run and wakes its first connection (tests and storylines).
    package static func wake(
        name: String, requirement: SecRequirement, directory: URL = defaultDirectory, fullControl: Bool = false
    ) throws -> LinkHost {
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        return try wake(
            run: LinkRun.allow(name: name, requirement: requirement, key: (text as String?) ?? "", fullControl: fullControl), directory: directory)
    }

    /// `~/Library/Application Support/Kore/link`.
    package static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kore", isDirectory: true).appendingPathComponent("link", isDirectory: true)
    }

    private init(run: LinkRun, directory: URL, feed: LinkFeed = .shared) throws {
        self.run = run
        self.feed = feed
        secret = Data(base64Encoded: LinkProof.random(32)) ?? Data()
        // A socket an earlier run left behind is removed here.
        if let stale = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in stale where file.hasSuffix(".sock") { unlink(directory.appendingPathComponent(file).path) }
        }
        let token = LinkProof.random(9).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        socketPath = directory.appendingPathComponent("\(token).sock").path
        listener = try LinkListener(path: socketPath, queue: queue)
        let pinned = PinnedRequirement(run.requirement)
        listener.start { [weak self] fd in
            // On the link's queue: who it is is checked before anything is read.
            guard LinkIdentity.peerPasses(fd, pinned.value) else {
                Darwin.close(fd)
                return
            }
            LinkHost.onMain { self?.accepted(fd) }
        }
        UILog.event("link-woken", [:])
        // The socket lives only while a client is on its way: one that never comes leaves nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectWithin) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, LinkHost.current === self, !self.linked, self.session == nil else { return }
                self.end(.disconnected)
            }
        }
    }

    /// Ends this connection: `bye` to a client still there, the socket removed, every hook let
    /// go. The companion stays allowed for the run (`LinkRun.revoke` ends that).
    package func end(_ reason: LinkMessage.ByeReason) {
        guard LinkHost.current === self else { return }
        LinkHost.current = nil
        if let session {
            if let peer = session.peer { feed.detach(peer.client) }
            // After what the sink still has queued for it.
            let connection = session.connection
            let bye = try? LinkMessage.bye(reason).encoded()
            sinkQueue.async { connection.finish(after: bye) }
        }
        session = nil
        listener.close()
        feed.layoutChanged = nil
        feed.swept = nil
        Workspace.showLinkMark(nil)
        LinkPanel.closePopup()
        UILog.event("link-ended", ["reason": reason.rawValue])
    }

    /// Runs `work` on the main thread, in order.
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Connections

    private func accepted(_ fd: Int32) {
        guard LinkHost.current === self, session == nil else {
            // One client at a time.
            Darwin.close(fd)
            return
        }
        let connection = LinkConnection(
            fd: fd, queue: queue,
            onFrames: { [weak self] frames in LinkHost.onMain { self?.received(frames) } },
            onClose: { [weak self] oversize in LinkHost.onMain { self?.dropped(oversize: oversize) } },
            onSlow: { [weak self] in LinkHost.onMain { self?.end(.slow) } })
        let session = Session(connection: connection)
        self.session = session
        connection.start()
        send(.challenge(nonce: session.nonce))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloWithin) { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session, self.session === session, !session.proven else { return }
                self.refuse(.auth)
            }
        }
    }

    /// The client went away: this connection ends. The companion reconnects by ringing again.
    private func dropped(oversize: Bool) {
        guard LinkHost.current === self, let session else { return }
        self.session = nil
        if let peer = session.peer { feed.detach(peer.client) }
        if oversize { return end(.invalid) }
        if session.proven { UILog.event("link-dropped", [:]) }
        end(.disconnected)
    }

    /// A connection that didn't prove itself: `bye`, then closed. Before any client was linked,
    /// the link stays open for the right one.
    private func refuse(_ reason: LinkMessage.ByeReason) {
        guard let session else { return }
        self.session = nil
        session.connection.finish(after: try? LinkMessage.bye(reason).encoded())
        UILog.event("link-refused", ["reason": reason.rawValue])
    }

    /// Before the hello: straight to the socket. After it, through the sink, in order with the
    /// feed's batches.
    private func send(_ message: LinkMessage) {
        guard let session else { return }
        if let peer = session.peer { return peer.send(message) }
        guard let data = try? message.encoded() else { return }
        session.connection.send(data)
    }

    private func received(_ frames: [Data]) {
        for frame in frames {
            guard let session, LinkHost.current === self else { return }
            guard let message = try? LinkMessage.decode(frame) else {
                return session.proven ? end(.invalid) : refuse(.invalid)
            }
            guard let peer = session.peer else {
                hello(message, session)
                continue
            }
            if case .bye = message {
                // The client is going; it may ring again this run.
                return end(.quit)
            }
            peer.received(message)
        }
    }

    private func hello(_ message: LinkMessage, _ session: Session) {
        guard case .hello(let proto, let client, let proof, let commands, _) = message else { return refuse(.invalid) }
        guard proto.major == LinkProto.major else { return refuse(.version) }
        guard LinkProof.check(proof, secret: secret, nonce: session.nonce) else { return refuse(.auth) }
        let connection = session.connection
        let sink = LinkSink(queue: sinkQueue) { data in connection.send(data) }
        let feedClient = LinkFeed.Client(sink: sink, full: run.fullControl, phone: false, sweeps: true)
        let peer = LinkPeer(grant: .companion(run.control), feed: feed, client: feedClient)
        let mark = mark
        peer.did = { mark.record($0) }
        peer.ends = { [weak self] reason in self?.end(reason) }
        peer.who = run.companionID
        session.peer = peer
        run.offer(commands)
        Workspace.showLinkMark(mark)
        feed.layoutChanged = { Workspace.showLinkMark(mark) }
        feed.swept = { Workspace.showLinkMark(mark) }
        UILog.event("link-linked", ["build": String(client.build.prefix(32)), "commands": "\(run.commands.count)"])
        send(
            .welcome(
                .init(
                    proto: LinkProto.version, epoch: LinkRun.epoch, host: .init(name: Host.current().localizedName ?? "Mac", koreVersion: Self.version),
                    providers: LinkSnapshot.providers(), policy: .init(sendMaxLevel: LinkPolicy.sendMaxLevel, control: run.control),
                    caps: ["tx", "attn", "blob", "commands", "control"])))
        // The snapshot, then what needs the user now (turn ends from before it connected aren't news).
        feed.attach(feedClient)
        feed.tick()
        send(feed.attentionState(after: nil))
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// An action as the mark lists it: what it did, and in which chat. Never what was said.
    static func describe(_ command: LinkCommand, chat: Chat?) -> String {
        let what: String =
            switch command {
            case .send: "Sent a message"
            case .stop: "Stopped"
            case .answer(_, _, let action, _, _):
                switch action {
                case .allow: "Allowed"
                case .deny: "Denied"
                case .approvePlan: "Approved a plan"
                case .keepPlanning: "Kept planning"
                case .submitAnswers: "Answered"
                case .implement: "Implemented the plan"
                case .stay: "Stayed in plan"
                default: "Answered"
                }
            case .setMode: "Lowered the mode"
            case .setPlan(_, let on): on ? "Turned plan on" : "Turned plan off"
            case .planReady(_, let choice): choice == .implement ? "Implemented the plan" : "Stayed in plan"
            case .new: "Started a chat"
            case .control(let kind, _): Self.describe(kind)
            case .unknown: "Acted"
            }
        return chat.map { "\(what) · \($0.title)" } ?? what
    }

    static func describe(_ kind: ControlKind) -> String {
        switch kind {
        case .chatRename: "Renamed"
        case .chatClose: "Closed"
        case .chatSelect: "Showed"
        case .chatSetModel: "Changed the model"
        case .chatSetEffort: "Changed the effort"
        case .chatSetFast: "Changed fast mode"
        case .chatCompact: "Compacted"
        case .chatSetAutoCompact: "Changed auto-compact"
        case .chatFork: "Forked"
        case .chatRetry: "Retried"
        case .chatContinue: "Continued"
        case .chatSendAtReset: "Set a message for the reset"
        case .chatCancelContinue: "Cancelled the continue"
        case .chatNew: "Started a chat"
        case .chatSetDraft: "Changed the draft"
        case .tabMove: "Moved a tab"
        case .tabReopen: "Reopened a tab"
        case .groupSet, .groupEdit, .groupUngroup: "Changed a tab group"
        case .groupClose: "Closed a tab group"
        case .boardNew: "Made a board"
        case .boardAttach, .boardDetach, .boardSection: "Changed a board"
        case .windowOpen: "Opened a folder"
        case .windowReopen: "Reopened a window"
        case .windowClose: "Closed a window"
        case .historyOpen: "Opened a past chat"
        case .historyRename: "Renamed a past chat"
        case .historyArchive: "Archived a past chat"
        case .macStayAwake: "Changed Stay awake"
        case .accountSignIn: "Started a sign-in"
        case .accountSubmit: "Sent a sign-in code"
        case .accountCancel: "Cancelled a sign-in"
        case .accountSwitch: "Switched login"
        case .accountRemove: "Removed a login"
        case .accountSignOut: "Signed out"
        case .accountRefresh: "Read the account"
        case .accountPrivacy: "Changed email privacy"
        case .chatSetArsenal: "Changed Arsenal"
        case .arsenalStopAll: "Stopped agent control"
        case .foldersList, .folderAdd, .authGh, .syncWatch, .syncUnwatch, .fsList, .fsRead, .fsMkdir, .fsWrite, .fsCreate, .fsRename, .fsDelete, .fsSearch, .fsWatch, .fsCopy, .fsCount, .fsCancel,
            .chatRelease, .chatAdopt, .chatMirror, .syncFlush, .chatCopy, .chatAdoptCopy, .syncApply, .fsStat, .fsFind:
            "Acted"
        }
    }

    // MARK: For tests and storylines

    /// A client is linked and proven.
    package var linked: Bool { session?.proven == true }
    /// The companion's feed client (tests).
    var feedClient: LinkFeed.Client? { session?.peer?.client }
    /// The user chose one of the companion's commands in "/": told to the client, no reply.
    func command(_ id: String) {
        guard linked else { return }
        UILog.event("link-command", [:])
        send(.command(id: id))
    }
    /// The mark's recent lines.
    package var recent: [String] { mark.recent }
}
