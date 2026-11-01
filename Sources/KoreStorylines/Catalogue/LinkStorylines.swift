import CryptoKit
import Darwin
import Foundation
import KoreLink
import KoreUI

/// The local link end to end (`z-docs/link-protocol.md`): a ring shows Kore's card, Allow wakes a
/// connection, a client on the socket proves itself (offering one command) and the title row's
/// mark shows; it gets a snapshot holding the chat, a raise of the mode is refused, a message it
/// sends is answered and the change comes back as a delta. The client drops: nothing stays awake
/// and "/" offers "Open"; it rings again with its proof and reconnects with no card, its command
/// is chosen in "/" and reaches it; Disconnect in the mark's popup ends the run with `bye`, and
/// the same proof is refused after. The client is this process, pinned by its own requirement.
final class LinkRingAndAct: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let reply = "Done, over the link."
    static let message = "Hello from the companion"
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        let client = LinkStoryClient()
        return super.steps() + [
            Do("start with no link") { _ in LinkStoryClient.reset() },
            Do("ring the doorbell") { _ in try client.ring() },
            WaitForElement(.id(StoryID.Link.card)),
            Expect("a moment before Allow takes a press") { _ in Date() > client.rungAt.addingTimeInterval(0.9) },
            Press(.id(StoryID.Link.allow)),
            Expect("the link awake, with its socket, and no mark before a client") { _ in
                client.socket != nil && LinkHost.current != nil && client.runSecret != nil
            },
            ExpectElement(.id(StoryID.Link.mark), .absent),
            Do("connect, answer the challenge, say hello with a command") { _ in client.connect(commands: [.init(id: "qr", label: "Show code")]) },
            Expect("a welcome, then a snapshot holding the chat", found: { _ in client.types.joined(separator: ",") }) { story in
                let chat = try story.activeChat().id.uuidString
                return client.welcomed && client.snapshotChats.contains(chat)
            },
            WaitForElement(.id(StoryID.Link.mark)),
            Do("ask to raise the chat's mode") { story in
                let chat = try story.activeChat()
                let current = chat.provider.modes.first { $0.id == chat.controls.mode }?.level ?? 1
                guard let higher = chat.controls.availableModes.first(where: { $0.level > current }) else {
                    throw StoryFailure.other("no higher mode to ask for")
                }
                client.send(.cmd(id: "raise", .setMode(chatId: chat.id.uuidString, modeId: higher.id)))
            },
            Expect("refused as a raise", found: { _ in client.result("raise").map { "\($0)" } }) { _ in
                client.result("raise")?.code == .raiseMode
            },
            Do("send a message over the link") { story in
                client.send(.cmd(id: "send", .send(chatId: try story.activeChat().id.uuidString, text: Self.message)))
            },
            Expect("the send went through") { _ in client.result("send")?.ok == true },
            TurnFinished(1),
            Expect.rows("the message, then the answer") { rows in
                guard let sent = rows.firstIndex(where: { $0.kind == "user" && $0.text == Self.message }) else { return false }
                return rows[(sent + 1)...].contains { $0.kind == "assistant" && $0.text == Self.reply }
            },
            Expect("the chat's change came back as a delta") { _ in client.types.contains("delta") },
            Expect("the mark lists the send") { _ in LinkHost.current?.recent.first?.hasPrefix("Sent a message") == true },
            // The client goes: the connection ends, the run stays allowed and asleep.
            Do("the client drops") { _ in client.drop() },
            Expect("no connection, no socket, no taps; still allowed") { _ in
                LinkHost.current == nil && LinkRun.current != nil && !LinkTaps.on && !FileManager.default.fileExists(atPath: client.socket ?? "/")
            },
            ExpectElement(.id(StoryID.Link.mark), .absent),
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(.id(StoryID.Composer.command("link-open"))),
            ExpectElement(.id(StoryID.Composer.command("link-disconnect")), .exists),
            ExpectElement(.id(StoryID.Composer.command("link-cmd-qr")), .absent),
            Press(.id(StoryID.Composer.slash)),
            // It rings again with its proof: a new socket and secret at once, no card.
            Do("ring again with the run's proof") { _ in try client.rering() },
            Expect("answered at once, no card") { _ in client.socket != nil && !LinkPanel.cardOpen && LinkHost.current != nil },
            Do("connect again") { _ in client.connect(commands: [.init(id: "qr", label: "Show code")]) },
            Expect("welcomed again, same epoch") { _ in client.welcomed && client.epochs.count == 2 && Set(client.epochs).count == 1 },
            WaitForElement(.id(StoryID.Link.mark)),
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(.id(StoryID.Composer.command("link-cmd-qr"))),
            Press(.id(StoryID.Composer.command("link-cmd-qr"))),
            Expect("the command reached the client") { _ in client.commandsTold == ["qr"] },
            Press(.id(StoryID.Link.mark)),
            WaitForElement(.id(StoryID.Link.disconnect)),
            Press(.id(StoryID.Link.disconnect)),
            Expect("bye, then no link, no socket, no allowance") { _ in
                client.bye == .disconnected && LinkHost.current == nil && LinkRun.current == nil
                    && !FileManager.default.fileExists(atPath: client.socket ?? "/")
            },
            ExpectElement(.id(StoryID.Link.mark), .absent),
            Do("ring with a proof after Disconnect") { _ in try client.rering(expectRefused: true) },
            Expect("refused: no connection") { _ in LinkHost.current == nil && client.reringRefused },
        ]
    }
}

/// A ring is denied: no socket, no link, and the same sender's next ring is answered `denied`
/// without a card.
final class LinkRingDenied: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let client = LinkStoryClient()
        return super.steps() + [
            Do("start with no link") { _ in LinkStoryClient.reset() },
            Do("ring the doorbell") { _ in try client.ring(key: "denied-sender") },
            WaitForElement(.id(StoryID.Link.card)),
            Press(.id(StoryID.Link.deny)),
            Expect("answered denied, nothing awake") { _ in client.answer == .denied && LinkHost.current == nil },
            ExpectElement(.id(StoryID.Link.card), .absent),
            Do("ring again") { _ in try client.ring(key: "denied-sender") },
            Expect("denied at once, no card") { _ in client.answer == .denied && !LinkPanel.cardOpen },
            Do("forget the refusal") { _ in LinkDoorbell.forgetRefusals() },
        ]
    }
}

/// The storylines' companion: rings in-process, then talks to the socket from a thread of its own.
/// The link opens a chat no tab has shown (one it made, as a restored tab would be): Kore starts
/// it in the background and serves its page, and the tab the owner is on stays selected. It sends
/// to a chat in a mode where tools don't ask, which the link may do in every mode.
final class LinkOpensUnstartedChat: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Done.")]) }

    override func steps() -> [any Step] {
        let client = LinkStoryClient()
        var active: UUID?
        var made: String?
        return super.steps() + [
            Do("start with no link") { _ in LinkStoryClient.reset() },
            Do("ring, then Allow") { _ in try client.ring() },
            WaitForElement(.id(StoryID.Link.card)),
            Expect("a moment before Allow takes a press") { _ in Date() > client.rungAt.addingTimeInterval(0.9) },
            Press(.id(StoryID.Link.allow)),
            Do("connect") { _ in client.connect() },
            Expect("welcomed, with a window") { _ in client.welcomed && !client.snapshotWindows.isEmpty },
            Do("make a chat over the link") { story in
                active = story.app.workspace?.activeTab.id
                // This storyline's window: others' may still be open in the same run.
                let folder = story.app.workspace?.folder.lastPathComponent
                guard let window = client.snapshotWindows.first(where: { $0.name == folder })?.id else { throw StoryFailure.other("no window") }
                client.send(.cmd(id: "new", .new(windowId: window, provider: try story.activeChat().provider.id)))
            },
            Expect("made, in a tab no one has shown", found: { _ in client.result("new").map { "\($0)" } }) { story in
                guard let id = client.result("new")?.chatId else { return false }
                made = id
                let chat = story.app.workspace?.tabs.lazy.compactMap(\.chat).first { $0.id.uuidString == id }
                return chat.map { !$0.hasStarted } ?? false
            },
            Do("open its transcript") { _ in client.send(.txOpen(chatId: made ?? "", last: 60)) },
            Expect("started in the background, its page served, the same tab selected") { story in
                let chat = story.app.workspace?.tabs.lazy.compactMap(\.chat).first { $0.id.uuidString == made }
                return chat?.hasStarted == true && client.pagedChats.contains(made ?? "") && story.app.workspace?.activeTab.id == active
            },
            Do("put the chat in the most permissive mode, in Kore") { story in
                let chat = try story.activeChat()
                guard let top = chat.controls.availableModes.max(by: { $0.level < $1.level }) else { throw StoryFailure.other("no modes") }
                chat.setMode(top.id, remember: false)
            },
            Do("send to it over the link") { story in
                client.send(.cmd(id: "send", .send(chatId: try story.activeChat().id.uuidString, text: "From the link")))
            },
            Expect("taken in that mode", found: { _ in client.result("send").map { "\($0)" } }) { _ in client.result("send")?.ok == true },
            Do("disconnect") { _ in LinkRun.current?.revoke() },
        ]
    }
}

/// Link 1.1: the chat's "/" commands in its meta and sendable, Kore's own entries and "!" refused;
/// an image and a text file uploaded, checked and attached to a message; a bad hash and an
/// oversize upload refused; the message's image read back as a thumbnail, and a ref the
/// transcript doesn't hold refused.
final class LinkFilesAndCommands: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let review = SlashCommand(name: "review", description: "Review a pull request", hint: "", kind: .command)
    override class var script: CLIScript {
        CLIScript(start: [.controls(commands: [review])], turns: [CLIScript.reply("Looked at both.")])
    }
    /// A 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    static let text = Data("total = round(sub * (1 + tax))\n".utf8)

    override func steps() -> [any Step] {
        let client = LinkStoryClient()
        var chatId = ""
        var blobs: [String] = []
        return super.steps() + [
            Do("start with no link") { _ in LinkStoryClient.reset() },
            Do("ring, then Allow") { _ in try client.ring() },
            WaitForElement(.id(StoryID.Link.card)),
            Expect("a moment before Allow takes a press") { _ in Date() > client.rungAt.addingTimeInterval(0.9) },
            Press(.id(StoryID.Link.allow)),
            Do("connect") { story in
                chatId = try story.activeChat().id.uuidString
                client.connect()
            },
            Expect("welcomed with files and commands") { _ in client.caps.contains("blob") && client.caps.contains("commands") },
            Expect("the chat's commands listed, Kore's own left out", found: { _ in client.meta(chatId)?.commands.map { "\($0.map(\.name))" } }) { _ in
                let names = client.meta(chatId)?.commands?.map(\.name) ?? []
                return names.contains("review") && !names.contains("usage") && !names.contains("account")
            },
            Do("send /review, /usage and a shell line") { _ in
                client.send(.cmd(id: "slash", .send(chatId: chatId, text: "/review")))
                client.send(.cmd(id: "kore", .send(chatId: chatId, text: "/usage")))
                client.send(.cmd(id: "shell", .send(chatId: chatId, text: "!ls")))
            },
            Expect("/review taken; /usage and ! refused", found: { _ in ["slash", "kore", "shell"].map { "\(client.result($0).map { "\($0)" } ?? "-")" }.joined(separator: " | ") }) { _ in
                client.result("slash")?.ok == true && client.result("kore")?.code == .command && client.result("shell")?.code == .command
            },
            TurnFinished(1),
            Do("upload an image and a text file, a bad hash and an oversize file") { _ in
                client.upload("img", name: "screen.png", mime: "image/png", data: Self.png)
                client.upload("txt", name: "total.ts", mime: "text/plain", data: Self.text)
                client.upload("bad", name: "x.png", mime: "image/png", data: Self.png, sha: String(repeating: "0", count: 64))
                client.send(.blobPutBegin(uploadId: "big", name: "big.bin", mime: "application/octet-stream", size: LinkUploads.maxSize + 1, sha256: String(repeating: "a", count: 64)))
            },
            Expect("both kept, the bad hash and the oversize refused", found: { _ in ["img", "txt", "bad", "big"].map { "\(client.result("blob.put:" + $0).map { "\($0)" } ?? "-")" }.joined(separator: " | ") }) { _ in
                guard let a = client.result("blob.put:img")?.blobId, let b = client.result("blob.put:txt")?.blobId else { return false }
                blobs = [a, b]
                return client.result("blob.put:bad")?.code == .badHash && client.result("blob.put:big")?.code == .tooLarge
            },
            Do("send a message with both") { _ in client.send(.cmd(id: "files", .send(chatId: chatId, text: "Both files", blobs: blobs))) },
            Expect("taken", found: { _ in client.result("files").map { "\($0)" } }) { _ in client.result("files")?.ok == true },
            TurnFinished(2),
            Expect("the message holds the image and the file") { story in
                let entry = try story.activeChat().transcript.entries.last { $0.kind == .user && $0.text == "Both files" }
                let kinds = entry?.linkAttachments.map(\.linkKind) ?? []
                return kinds == [.image, .text]
            },
            Do("read the image back as a thumbnail, and a ref the chat doesn't hold") { story in
                let entry = try story.activeChat().transcript.entries.last { $0.kind == .user && $0.text == "Both files" }
                let ref = "\(entry?.id.uuidString ?? "")/0"
                client.send(.blobGet(id: "thumb", chatId: chatId, ref: ref, variant: .thumb, offset: 0))
                client.send(.blobGet(id: "stray", chatId: chatId, ref: "\(UUID().uuidString)/0", variant: .full, offset: 0))
                client.send(.blobGet(id: "path", chatId: chatId, ref: "../../etc/passwd", variant: .full, offset: 0))
            },
            Expect("a JPEG thumbnail; the others refused", found: { _ in "\(client.chunk("thumb").map { ($0.mime, $0.total) } as Any) \(client.result("stray").map { "\($0)" } ?? "-")" }) { _ in
                client.chunk("thumb")?.mime == "image/jpeg" && (client.chunk("thumb")?.total ?? 0) > 0
                    && client.result("stray")?.code == .deniedRef && client.result("path")?.code == .deniedRef
            },
            Do("disconnect") { _ in LinkRun.current?.revoke() },
        ]
    }
}

final class LinkStoryClient: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [LinkMessage] = []
    private var fd: Int32 = -1
    private(set) var rungAt = Date.distantPast
    private(set) var answer: LinkDoorbell.Answer?
    private var secret = Data()
    private(set) var socket: String?
    private(set) var runSecret: Data?
    private(set) var reringRefused = false

    /// No link left from an earlier storyline in the same run (one that failed before its own
    /// Disconnect): no run, connection, card or popup, and no refusals.
    @MainActor
    static func reset() {
        LinkRun.current?.revoke()
        LinkPanel.closeCard()
        LinkPanel.closePopup()
        LinkDoorbell.forgetRefusals()
    }

    /// Rings with this process's own requirement, as a sender keyed `key`.
    @MainActor
    func ring(key: String = "storyline") throws {
        guard let own = LinkIdentity.ownRequirement() else { throw StoryFailure.other("no code identity for this process") }
        rungAt = Date()
        answer = nil
        let directory = URL(fileURLWithPath: "/tmp/kls-\(UUID().uuidString.prefix(8))", isDirectory: true)
        LinkDoorbell.ask(name: "Story companion", requirement: own.0, key: key, directory: directory) { [self] answer in
            self.answer = answer
            if case .allowed(let socket, let secret, let runSecret) = answer {
                self.socket = socket
                self.secret = secret
                self.runSecret = runSecret
            }
        }
    }

    /// Rings again as the allowed companion: the run's proof over its epoch and now.
    @MainActor
    func rering(expectRefused: Bool = false) throws {
        guard let runSecret else { throw StoryFailure.other("no run secret from the first Allow") }
        let ts = Int(Date().timeIntervalSince1970)
        let proof = LinkProof.ringProof(runSecret: runSecret, epoch: LinkRun.epoch, ts: ts)
        let directory = URL(fileURLWithPath: "/tmp/kls-\(UUID().uuidString.prefix(8))", isDirectory: true)
        switch LinkDoorbell.rering(token: nil, proof: proof, ts: ts, directory: directory) {
        case .allowed(let socket, let secret, _)?:
            self.socket = socket
            self.secret = secret
            lock.withLock { messages.removeAll { if case .welcome = $0 { false } else { true } } }
        default:
            reringRefused = true
            if !expectRefused { throw StoryFailure.other("the re-ring was refused") }
        }
    }

    /// The client goes away without `bye`.
    func drop() {
        let fd = lock.withLock { () -> Int32 in
            let fd = self.fd
            self.fd = -1
            return fd
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    /// Connects and says hello, offering `commands`; reads every message after on its own thread.
    func connect(commands: [LinkMessage.CompanionCommand]? = nil) {
        guard let path = socket else { return }
        let secret = self.secret
        Thread.detachNewThread { [self] in
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { self.fd = fd }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                guard n > 0 else { break }
                buffer.append(contentsOf: chunk[0..<n])
                guard let frames = try? LinkFrame.take(&buffer, max: LinkFrame.outboundMax) else { break }
                for frame in frames {
                    guard let message = try? LinkMessage.decode(frame) else { continue }
                    if case .challenge(let nonce) = message {
                        send(.hello(proto: LinkProto.version, client: .init(name: "story", build: "1"), proof: LinkProof.proof(secret: secret, nonce: nonce), commands: commands))
                    }
                    lock.withLock { messages.append(message) }
                }
            }
            Darwin.close(fd)
        }
    }

    func send(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        let frame = LinkFrame.frame(data)
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    var types: [String] { lock.withLock { messages.map(\.type) } }

    var welcomed: Bool { lock.withLock { messages.contains { if case .welcome = $0 { true } else { false } } } }

    /// Every welcome's epoch, in order.
    var epochs: [String] { lock.withLock { messages.compactMap { if case .welcome(let w) = $0 { w.epoch } else { nil } } } }

    /// The commands Kore told it the user chose.
    var commandsTold: [String] { lock.withLock { messages.compactMap { if case .command(let id) = $0 { id } else { nil } } } }

    var snapshotChats: [String] {
        lock.withLock {
            messages.compactMap { if case .snapshot(_, _, let chats) = $0 { chats.map(\.id) } else { nil } }.flatMap { $0 }
        }
    }

    /// The windows of the first snapshot.
    var snapshotWindows: [LinkWindow] {
        lock.withLock { messages.lazy.compactMap { if case .snapshot(_, let windows, _) = $0 { windows } else { nil } }.first ?? [] }
    }

    /// The chats a `tx.page` came for.
    var pagedChats: Set<String> {
        lock.withLock { Set(messages.compactMap { if case .txPage(let chatId, _, _, _, _) = $0 { chatId } else { nil } }) }
    }

    func result(_ id: String) -> LinkMessage.Result? {
        lock.withLock { messages.lazy.compactMap { if case .result(let r) = $0, r.id == id { r } else { nil } }.first }
    }

    /// The welcome's capabilities.
    var caps: [String] { lock.withLock { messages.lazy.compactMap { if case .welcome(let w) = $0 { w.caps } else { nil } }.first ?? [] } }

    /// A chat's latest meta, from snapshots and deltas.
    func meta(_ chatId: String) -> ChatMeta? {
        lock.withLock {
            messages.reversed().lazy.compactMap { message -> ChatMeta? in
                switch message {
                case .snapshot(_, _, let chats), .delta(_, _, .some(let chats), _): chats.first { $0.id == chatId }
                default: nil
                }
            }.first
        }
    }

    /// A `blob.get`'s first piece.
    func chunk(_ id: String) -> (mime: String, total: Int, data: String)? {
        lock.withLock {
            messages.lazy.compactMap { if case .blobChunk(let i, let mime, _, let total, let data) = $0, i == id { (mime, total, data) } else { nil } }.first
        }
    }

    /// Uploads `data` whole: begin, 48 KB chunks, end. `sha` overrides its SHA-256.
    func upload(_ uploadId: String, name: String, mime: String, data: Data, sha: String? = nil) {
        let digest = sha ?? LinkUploads.hex(SHA256.hash(data: data))
        send(.blobPutBegin(uploadId: uploadId, name: name, mime: mime, size: data.count, sha256: digest))
        var index = 0
        var offset = 0
        while offset < data.count {
            let piece = data[offset..<min(offset + LinkUploads.chunkMax, data.count)]
            send(.blobPutChunk(uploadId: uploadId, index: index, data: Data(piece).base64EncodedString()))
            index += 1
            offset += piece.count
        }
        send(.blobPutEnd(uploadId: uploadId))
    }

    var bye: LinkMessage.ByeReason? {
        lock.withLock { messages.lazy.compactMap { if case .bye(let reason) = $0 { reason } else { nil } }.first }
    }
}

/// Navigation with a client linked and following all three chats: the same work as `NavCost`
/// (switching, scrolling), then sends timed until the message is in the chat, and the link's
/// tick times. `LinkedNavCostAsleep` runs the same steps with no ring, for the send's baseline.
/// Nothing is asserted; the numbers go to `nav.notes`.
class LinkedNavCost: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    class var linked: Bool { true }

    static func script(_ chat: Int) -> CLIScript {
        CLIScript(turns: (1...9).map { turn in [.startTurn, .stream(.answer, NavCost.answer(chat, turn: turn), chunk: 4000), .finishTurn(.completed)] })
    }

    static func chat(_ n: Int) -> [any Step] {
        [UseScript(script(n)), StartChat("claude")] + (1...4).flatMap { turn -> [any Step] in
            [Send("chat \(n), turn \(turn)"), TurnFinished(turn)]
        }
    }

    override func steps() -> [any Step] {
        let client = LinkStoryClient()
        var link: [any Step] = []
        if Self.linked {
            link = [
                Do("ring the doorbell") { _ in try client.ring(key: "nav") },
                WaitForElement(.id(StoryID.Link.card)),
                Expect("a moment before Allow takes a press") { _ in Date() > client.rungAt.addingTimeInterval(0.9) },
                Press(.id(StoryID.Link.allow)),
                Expect("the link awake") { _ in client.socket != nil },
                Do("connect") { _ in client.connect() },
                Expect("a snapshot") { _ in client.snapshotChats.count >= 3 },
                Do("follow every chat") { _ in for id in client.snapshotChats { client.send(.txOpen(chatId: id, last: 60)) } },
                Expect("a page for each") { _ in client.types.filter { $0 == "tx.page" }.count >= 3 },
            ]
        }
        return [OpenFolder()] + Self.chat(1) + Self.chat(2) + Self.chat(3) + link + [
            WaitIdle(), MeasureNav(), MeasureSends(), RecordLinkTicks(),
            Do("end the link") { _ in LinkRun.current?.revoke() },
        ]
    }
}

final class LinkedNavCostAsleep: LinkedNavCost {
    override class var linked: Bool { false }
}

/// Five sends in the active chat, each timed from the send to the message in the chat, its turn
/// left to finish before the next.
struct MeasureSends: Step {
    var label: String { "Measure sends" }
    var timeout: Duration? { .seconds(120) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        var times: [Double] = []
        for n in 1...5 {
            let text = "measured send \(n)"
            let start = ContinuousClock.now
            chat.storySend(text)
            try await story.until("“\(text)” in the chat") {
                story.chatEvents(chat).contains { if case .userMessage(let body, _, _) = $0 { body == text } else { false } }
            }
            let d = ContinuousClock.now - start
            times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            try await story.until("the turn after “\(text)”") { !chat.isRunning }
        }
        let sorted = times.sorted()
        let line = "\(story.name) send: \(times.count) median \(String(format: "%.1f", sorted[sorted.count / 2])) ms, max \(String(format: "%.1f", sorted.last ?? 0))\n"
        try NavNotes.append(line, story)
    }
}

/// The link's tick times while linked: median, p99 and max.
struct RecordLinkTicks: Step {
    var label: String { "Record the link's ticks" }

    func run(_ story: StoryContext) async throws {
        guard let host = LinkHost.current else { return }
        let ms = host.tickTimes.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }.sorted()
        guard !ms.isEmpty else { return }
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        let p99 = ms[min(ms.count - 1, Int((Double(ms.count - 1) * 0.99).rounded()))]
        try NavNotes.append("\(story.name) link ticks: \(ms.count) median \(f(ms[ms.count / 2])) ms, p99 \(f(p99)), max \(f(ms.last ?? 0))\n", story)
    }
}

enum NavNotes {
    @MainActor static func append(_ text: String, _ story: StoryContext) throws {
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
