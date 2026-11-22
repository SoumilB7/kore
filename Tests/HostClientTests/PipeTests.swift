import Foundation
import HostClient
import KoreCore
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import Testing
import src

/// A box's pipes in this process (phase 18 §1 "Bulk"): its book, identity and `HostPipes`, each
/// pipe session a socketpair with the box's end proven and served as kore-host serves it, and a
/// broker on this Mac's end as `BoxPipe` makes one. rsync runs for real at both ends, its remote
/// shell the built `kore pipe` (macOS's openrsync has no `--munge-links`: the forced options here
/// are the rest; the Docker rig runs the box's own rsync 3 with all of them).
final class PipeRig: @unchecked Sendable {
    static let macForced = PipeArgv.forced

    let root: URL
    let home: URL
    let box: FakeNetBox
    let mac = MacIdentity(device: UUID(), signer: SoftwareIdentity())
    let macBook: DeviceBook
    var pipes: HostPipes
    /// Each pipe's ticket asked (`pipe.open`'s words), in order.
    let asked = Mutex<[[String]]>([])

    init(home: URL? = nil, pipes: HostPipes? = nil) throws {
        root = netScratch()
        self.home = home ?? root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        let box = FakeNetBox(root: root)
        let macBook = DeviceBook(url: root.appendingPathComponent("mac-book.json"))
        self.box = box
        self.macBook = macBook
        self.pipes = pipes ?? HostPipes(home: self.home.path, rsync: "/usr/bin/rsync", forced: Self.macForced)
        try box.allow(mac: mac.device, key: mac.signer.publicKey)
        try macBook.update { $0.append(box.pinned) }
    }

    func finish() { try? FileManager.default.removeItem(at: root) }

    /// The built `kore pipe` (`kore-command`, beside the test bundle).
    static let helper: String? = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<2 { dir = dir.deletingLastPathComponent() }
        let built = [".build/debug/kore-command", ".build/out/Products/Debug/kore-command"].map { dir.appendingPathComponent($0).path }
        return built.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// A pipe session to the box, this Mac's end fresh (its handshake to come): the box's end is
    /// proven and served on a thread of its own, as `HostNet` hands it to `HostPipes`.
    func dial() throws -> NetSession {
        let (macEnd, boxEnd) = try Sockets.pair()
        let (book, device, identity, pipes, macDevice) = (box.book, box.device, box.identity, pipes, mac.device)
        let thread = Thread {
            let setup = NetSession.Server(
                local: NetLocal(device: device, kind: .box, nodeKey: Binding.Route.sshNodeKey, signer: identity), route: .ssh, peer: .ssh,
                book: book, tickets: ResumeTickets())
            let session = NetSession(fd: boxEnd, role: .server(setup))
            session.start()
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if case .established = session.state { return pipes.serve(session, device: macDevice) }
                if case .closed = session.state { return }
                var fd = pollfd(fd: boxEnd, events: Int16(POLLIN), revents: 0)
                _ = poll(&fd, 1, 100)
                _ = session.pump()
            }
        }
        thread.start()
        let setup = NetSession.Client(
            local: NetLocal(device: mac.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: mac.signer), route: .ssh, peer: .ssh,
            book: macBook, server: box.device, service: "pipe")
        return NetSession(fd: macEnd, role: .client(setup))
    }

    /// One broker, as `BoxPipe.eCommand` makes one: the box's ticket for the words (as the link's
    /// `pipe.open` would get it), the dial, the handshake.
    func broker() throws -> PipeBroker {
        let broker = try PipeBroker(directory: root.appendingPathComponent("pipes")) { [self] words throws(PipeHandshake.Failure) in
            asked.withLock { $0.append(words) }
            let ticket: Data
            switch pipes.open(argv: words, device: mac.device, served: []) {
            case .success(let value): ticket = value
            case .failure(let refusal): throw .closed(refusal.message)
            }
            let session: NetSession
            do { session = try dial() } catch { throw .closed("\(error)") }
            try PipeHandshake.open(session, ticket: ticket, within: 10)
            guard case .established(let peer) = session.state else { throw .closed("gone") }
            return (session, peer)
        }
        broker.start()
        return broker
    }

    /// `-e` for rsync through a broker of its own.
    func eCommand() throws -> String { try broker().eCommand(helper: try #require(Self.helper)) }

    /// rsync on this Mac, its remote the box over a pipe; its status and what it said.
    func rsync(_ arguments: [String]) async throws -> (status: Int32, said: String) {
        let e = try eCommand()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = ["-e", e] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(returning: 127) }
        }
        return (status, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Whether `condition` holds within `seconds` (looked at every few ms).
    static func within(_ seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// `box:'<path>'`, as `SyncBox.spec` names a box's path.
    func spec(_ path: String) -> String { "box:" + ShellQuote.single(path) }

    /// A SyncBox whose spawns go over this rig's pipes (`SyncBox.box` with the link on KoreNet).
    @MainActor func syncBox() -> SyncBox {
        var box = SyncBox.via("/usr/bin/false", alias: "box", base: home.path)
        box.pipe = SyncBox.PipeLink(usable: { true }, eCommand: { [self] in try? eCommand() })
        return box
    }
}

func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
    var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
    return Data((0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    })
}

@Suite("Pipes (rsync over KoreNet)", .serialized)
struct PipeTests {
    @Test func aFolderGoesToTheBoxAndBackOverAPipe() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let mac = rig.root.appendingPathComponent("mac/src", isDirectory: true)
        try FileManager.default.createDirectory(at: mac.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: mac.appendingPathComponent("a.txt"))
        try bytes(1 << 20).write(to: mac.appendingPathComponent("sub/b.bin"))
        let there = rig.home.appendingPathComponent("My Code/dst", isDirectory: true)
        let pushed = try await rig.rsync(["-a", "--partial", "--timeout=60", mac.path + "/", rig.spec(there.path + "/")])
        #expect(pushed.status == 0, "\(pushed.said)")
        #expect(try Data(contentsOf: there.appendingPathComponent("sub/b.bin")) == bytes(1 << 20))
        let back = rig.root.appendingPathComponent("mac/back", isDirectory: true)
        let pulled = try await rig.rsync(["-a", rig.spec(there.path + "/"), back.path + "/"])
        #expect(pulled.status == 0, "\(pulled.said)")
        #expect(try String(contentsOf: back.appendingPathComponent("a.txt"), encoding: .utf8) == "hello\n")
        #expect(try Data(contentsOf: back.appendingPathComponent("sub/b.bin")) == bytes(1 << 20))
        // Links arrive as they are, wherever they point, both ways (forced options once dropped
        // or rewrote them all), and a second copy sends nothing.
        let links = ["rel": "a.txt", "folder": "sub", "absolute": mac.path + "/a.txt", "outside": "/etc/hosts", "up": "../../elsewhere", "dangling": "nowhere"]
        for (name, to) in links { try FileManager.default.createSymbolicLink(atPath: mac.appendingPathComponent(name).path, withDestinationPath: to) }
        let pushedLinks = try await rig.rsync(["-a", mac.path + "/", rig.spec(there.path + "/")])
        #expect(pushedLinks.status == 0, "\(pushedLinks.said)")
        let pulledLinks = try await rig.rsync(["-a", rig.spec(there.path + "/"), back.path + "/"])
        #expect(pulledLinks.status == 0, "\(pulledLinks.said)")
        for (name, to) in links {
            for folder in [there, back] {
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(name).path)) == to, "\(name) in \(folder.lastPathComponent)")
            }
        }
        // Each spawn asked the box with openrsync's own words, quotes and all.
        #expect(rig.asked.withLock { $0.count } == 4)
        #expect(rig.asked.withLock { $0.first?.first } == "rsync" && rig.asked.withLock { $0.last?.contains("--sender") } == true)
        #expect(rig.pipes.running == 0 && rig.pipes.held(by: rig.mac.device) == 0)
    }

    /// What the box won't do: a path out of its home (or through a link out of it), a third pipe
    /// at once, a ticket spent or gone stale, another device's ticket.
    @Test func theBoxRefusesWhatItShouldnt() throws {
        let clock = Mutex(Date())
        let root = netScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("out").path, withDestinationPath: "/etc")
        let pipes = HostPipes(home: home.path, rsync: "/usr/bin/rsync", forced: PipeRig.macForced, now: { clock.withLock { $0 } })
        let me = UUID()
        func open(_ path: String, sender: Bool = false) -> Result<Data, HostPipes.Refusal> {
            pipes.open(argv: ["rsync", "--server"] + (sender ? ["--sender"] : []) + ["-r", ".", path], device: me, served: [])
        }
        #expect(throws: Never.self) { try open(home.path + "/new/deeper/").get() }
        #expect(open("/etc/").failureCode == .deniedPath)
        #expect(open(home.path + "/out/passwd", sender: true).failureCode == .deniedPath)
        #expect(open(home.path + "/out/new").failureCode == .deniedPath)
        #expect(open(home.path + "/missing", sender: true).failureCode == .goneFile)
        #expect(open("--server").failureCode == .invalid)
        // Two at once, tickets included; a third waits for one to end.
        let second = try open(home.path + "/").get()
        #expect(open(home.path + "/").failureCode == .rateLimited)
        #expect(pipes.redeem(second, device: UUID()) == nil, "another device's")
        #expect(pipes.redeem(second, device: me) == nil, "spent by the try above")
        // A ticket not spent within a minute goes.
        let late = try open(home.path + "/").get()
        clock.withLock { $0 += LinkPipe.ticketSeconds + 1 }
        #expect(pipes.redeem(late, device: me) == nil)
        #expect(pipes.held(by: me) == 0)
    }

    /// Revoked mid-copy: the box ends the pipe at once and its rsync with it; this Mac's rsync
    /// says so and stops. `--partial` kept what came, and the next run sends only the rest.
    @Test func aRevokeMidCopyStopsItAndTheNextRunFinishesIt() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let size = 48 << 20
        let source = rig.root.appendingPathComponent("mac/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(size, seed: 3).write(to: source)
        let there = rig.home.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        // Revoked as soon as the box has some of it.
        let watcher = Task.detached {
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: there.path)) ?? []
                let landed = names.compactMap { (try? FileManager.default.attributesOfItem(atPath: there.appendingPathComponent($0).path))?[.size] as? Int }.max() ?? 0
                if landed > 1 << 20 { return rig.pipes.stop { _ in true } }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let first = try await rig.rsync(["-a", "--partial", "--timeout=60", source.path, rig.spec(there.path + "/")])
        await watcher.value
        #expect(first.status != 0)
        #expect(first.said.contains("revoked"), "\(first.said)")
        #expect(await PipeRig.within(5) { rig.pipes.running == 0 })
        let second = try await rig.rsync(["-a", "--partial", "--timeout=60", "--stats", source.path, rig.spec(there.path + "/")])
        #expect(second.status == 0, "\(second.said)")
        #expect(try Data(contentsOf: there.appendingPathComponent("big.bin")) == bytes(size, seed: 3))
    }

    /// A revoke between the ticket's spending and the splice (rsync spawned, `go` not yet said)
    /// stops the copy as soon as there's something to stop.
    @Test func aRevokeWhileAPipeStartsStopsIt() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let ticket = try rig.pipes.open(argv: ["rsync", "--server", "-r", ".", rig.home.path + "/in/"], device: rig.mac.device, served: []).get()
        let session = try rig.dial()
        // Through `ready`, `go` not said: rsync runs, the splice isn't there yet.
        try PipeHandshake.open(session, ticket: ticket, within: 10)
        #expect(rig.pipes.running == 1)
        rig.pipes.stop { _ in true }
        try PipeHandshake.go(session)
        #expect(await PipeRig.within(5) { rig.pipes.running == 0 })
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            _ = session.pump()
            if case .closed(let why) = session.state {
                #expect(why == "bye revoked", "\(why)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the pipe went on after the revoke")
    }

    /// A peer that vanished without a hang-up ends the pipe; one that only has nothing to say
    /// (it answers pings) doesn't.
    @Test func aSilentPeerEndsThePipeAndAQuietOneDoesnt() async throws {
        func splice(answering: Bool) throws -> (ended: PipeSplice.Outcome?, after: TimeInterval) {
            let rig = try PipeRig()
            defer { rig.finish() }
            let pair = try LinkPair(rig)
            var fds: [Int32] = [-1, -1]
            #expect(pipe(&fds) == 0)
            defer { close(fds[1]) }
            let done = Mutex<PipeSplice.Outcome?>(nil)
            let splice = PipeSplice(session: pair.client, input: fds[0], output: nil, server: false, silence: .init(ask: 0.05, gone: 0.4))
            let started = Date()
            let thread = Thread { let outcome = splice.run(); done.withLock { $0 = outcome } }
            thread.start()
            while done.withLock({ $0 }) == nil, Date().timeIntervalSince(started) < 1.2 {
                if answering { _ = pair.server.pump() }
                usleep(5000)
            }
            let ended = done.withLock { $0 }
            if ended == nil { splice.stop("test") }
            while done.withLock({ $0 }) == nil { usleep(1000) }
            return (ended, Date().timeIntervalSince(started))
        }
        let silent = try splice(answering: false)
        #expect(silent.ended == .broken(NetControl.Reason.timeout) && silent.after < 1.2)
        #expect(try splice(answering: true).ended == nil)
    }

    /// Sessions that bring no ticket hold a thread each: no more than a device's pipes.
    @Test func noMoreThanTwoSessionsWaitForATicket() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let sessions = try (0..<3).map { _ in try rig.dial() }
        let open = { sessions.map { session -> Bool in _ = session.pump(); if case .closed = session.state { return false } else { return true } } }
        let end = Date().addingTimeInterval(5)
        var alive = open()
        while alive.filter({ $0 }).count > 2, Date() < end {
            try await Task.sleep(for: .milliseconds(10))
            alive = open()
        }
        #expect(alive.filter { $0 }.count == 2)
    }

    /// Box to box: the receiving box expects the Mac's ticket for the sending box's pipe into a
    /// folder (`pipe.expect`); the sender's command comes with the ticket on its session and is
    /// checked then: a push inside that folder lands, a pull or a path outside it is refused.
    @Test func aBoxExpectsAnotherBoxsPipeIntoOneFolderOnly() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let into = rig.home.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let source = rig.root.appendingPathComponent("a/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bytes(300_000).write(to: source.appendingPathComponent("x.bin"))
        // The sender's broker: the Mac's ticket, its own command on the session (as `kore-host pipe`).
        func sender() throws -> (broker: PipeBroker, ticket: Data) {
            let ticket = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            #expect(throws: Never.self) { try rig.pipes.expect(ticket: ticket, device: rig.mac.device, path: into.path, served: []).get() }
            let broker = try PipeBroker(directory: rig.root.appendingPathComponent("pipes")) { words throws(PipeHandshake.Failure) in
                let session: NetSession
                do { session = try rig.dial() } catch { throw .closed("\(error)") }
                try PipeHandshake.open(session, ticket: ticket, argv: words, within: 10)
                guard case .established(let peer) = session.state else { throw .closed("gone") }
                return (session, peer)
            }
            broker.start()
            return (broker, ticket)
        }
        func rsync(_ broker: PipeBroker, _ arguments: [String]) async throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = ["-e", broker.eCommand(helper: try #require(PipeRig.helper))] + arguments
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            return await withCheckedContinuation { done in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { done.resume(returning: 127) }
            }
        }
        let pushed = try sender()
        #expect(try await rsync(pushed.broker, ["-a", "--partial", source.path, rig.spec(into.path + "/")]) == 0)
        #expect(try Data(contentsOf: into.appendingPathComponent("proj/x.bin")) == bytes(300_000))
        // A ticket goes once: the same one again is refused.
        #expect(rig.pipes.redeem(pushed.ticket, device: rig.mac.device) == nil)
        let outside = try sender()
        #expect(try await rsync(outside.broker, ["-a", source.path, rig.spec(rig.home.path + "/")]) != 0)
        let pull = try sender()
        #expect(try await rsync(pull.broker, ["-a", rig.spec(into.path + "/proj/"), rig.root.appendingPathComponent("back").path]) != 0)
        #expect(!FileManager.default.fileExists(atPath: rig.home.appendingPathComponent("proj").path))
    }

    /// A 50 MB pipe beside the link: the link's own connection answers as quickly as before.
    @Test func theLinkStaysQuickUnderABigPipe() async throws {
        let rig = try PipeRig()
        defer { rig.finish() }
        let source = rig.root.appendingPathComponent("mac/fifty.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(50 << 20, seed: 9).write(to: source)
        let link = try LinkPair(rig)
        let idle = try link.pings(10)
        let copy = Task { try await rig.rsync(["-a", source.path, rig.spec(rig.home.path + "/")]) }
        // Pings while the bytes flow (the copy takes longer than these).
        try await Task.sleep(for: .milliseconds(50))
        let busy = try link.pings(20)
        let done = try await copy.value
        #expect(done.status == 0, "\(done.said)")
        let worst = busy.max() ?? 0
        print("link ping idle max \(idle.max() ?? 0) ms, under a 50 MB pipe max \(worst) ms")
        #expect(worst < 50, "a ping waited \(worst) ms behind the pipe")
    }
}

/// A link session pair (service "link") to time pings on.
final class LinkPair {
    let client: NetSession
    let server: NetSession

    init(_ rig: PipeRig) throws {
        let (a, b) = try Sockets.pair()
        let serverSetup = NetSession.Server(
            local: NetLocal(device: rig.box.device, kind: .box, nodeKey: Binding.Route.sshNodeKey, signer: rig.box.identity), route: .ssh, peer: .ssh,
            book: rig.box.book, tickets: ResumeTickets())
        server = NetSession(fd: b, role: .server(serverSetup))
        let clientSetup = NetSession.Client(
            local: NetLocal(device: rig.mac.device, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: rig.mac.signer), route: .ssh, peer: .ssh,
            book: rig.macBook, server: rig.box.device, service: "link")
        client = NetSession(fd: a, role: .client(clientSetup))
        server.start()
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            _ = server.pump()
            _ = client.pump()
            if case .established = client.state, case .established = server.state { return }
            usleep(1000)
        }
        throw PipeHandshake.Failure.timedOut
    }

    /// Each ping's round trip, in ms: the server answers as kore-host's would, on its own thread.
    func pings(_ count: Int) throws -> [Double] {
        var out: [Double] = []
        for _ in 0..<count {
            let started = Date()
            guard let n = client.ping() else { throw PipeHandshake.Failure.closed("link") }
            while client.lastPong != n {
                guard Date().timeIntervalSince(started) < 2 else { throw PipeHandshake.Failure.timedOut }
                var fds = [pollfd(fd: client.descriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: server.descriptor, events: Int16(POLLIN), revents: 0)]
                _ = poll(&fds, 2, 10)
                _ = server.pump()
                _ = client.pump()
            }
            out.append(Date().timeIntervalSince(started) * 1000)
        }
        return out
    }
}

extension Result where Failure == HostPipes.Refusal {
    var failureCode: ResultCode? {
        if case .failure(let refusal) = self { return refusal.code }
        return nil
    }
}
