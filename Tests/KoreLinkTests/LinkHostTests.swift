import AppKit
import Darwin
import Foundation
import Testing

@testable import KoreLink
@testable import KoreUI

/// A client on the link's socket, as a companion would be: blocking reads with a timeout, on a
/// thread of its own.
final class TestClient: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else {
            Darwin.close(fd)
            return nil
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ message: LinkMessage) {
        let data = LinkFrame.frame((try? message.encoded()) ?? Data())
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func sendRaw(_ data: Data) { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }

    /// The next message, or nil when the socket closed or nothing came within the timeout.
    func next() -> LinkMessage? {
        while true {
            if let frames = try? LinkFrame.take(&buffer, max: LinkFrame.outboundMax), let first = frames.first {
                // Put back what came after it.
                var rest = Data()
                for frame in frames.dropFirst() { rest.append(LinkFrame.frame(frame)) }
                buffer = rest + buffer
                return try? LinkMessage.decode(first)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Messages until one matches, or nil.
    func next(where match: (LinkMessage) -> Bool) -> LinkMessage? {
        while let message = next() {
            if match(message) { return message }
        }
        return nil
    }

    /// The socket closed (a read returns 0).
    func closedByPeer() -> Bool {
        while let _ = next() {}
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    func close() { Darwin.close(fd) }
}

/// Runs blocking client work off the main actor, so the host can answer.
func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached { work() }.value
}

@MainActor
@Suite("link host", .serialized)
struct LinkHostTests {
    static func directory() -> URL {
        URL(fileURLWithPath: "/tmp/kl-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    static func wake(_ requirement: String? = nil) throws -> LinkHost {
        let own = try #require(LinkIdentity.ownRequirement())
        let pinned = try requirement.map { try #require(LinkIdentity.requirement($0)) } ?? own.0
        return try LinkHost.wake(name: "Test companion", requirement: pinned, directory: directory())
    }

    /// Connects and proves itself; returns the client and the welcome.
    static func link(_ host: LinkHost, commands: [LinkMessage.CompanionCommand]? = nil) async throws -> (TestClient, LinkMessage.Welcome) {
        let path = host.socketPath
        let secret = host.secret
        let client = try #require(await off { TestClient(path: path) })
        let welcome: LinkMessage.Welcome? = await off {
            guard case .challenge(let nonce)? = client.next() else { return nil }
            client.send(.hello(proto: LinkProto.version, client: .init(name: "t", build: "1"), proof: LinkProof.proof(secret: secret, nonce: nonce), commands: commands))
            guard case .welcome(let w)? = client.next() else { return nil }
            return w
        }
        return (client, try #require(welcome))
    }

    @Test func socketIsPrivateAndGoesWithTheLink() async throws {
        let host = try Self.wake()
        let path = host.socketPath
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect(LinkHost.current === host)
        host.end(.disconnected)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(LinkHost.current == nil)
        LinkRun.current?.revoke()
    }

    @Test func helloWelcomeThenSnapshotAndAttention() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let (client, welcome) = try await Self.link(host)
        defer { client.close() }
        #expect(welcome.proto == LinkProto.version)
        #expect(welcome.epoch == LinkRun.epoch)
        #expect(welcome.policy.sendMaxLevel == .manual)
        #expect(welcome.providers.map(\.id) == ["claude", "codex"])
        let rest: [String] = await off {
            var types: [String] = []
            while types.count < 2, let m = client.next() { types.append(m.type) }
            return types
        }
        #expect(rest == ["snapshot", "attn.state"])
        #expect(host.linked)
    }

    @Test func aWrongProofIsRefused() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        let client = try #require(await off { TestClient(path: path) })
        defer { client.close() }
        let answer: LinkMessage? = await off {
            _ = client.next()
            client.send(.hello(proto: LinkProto.version, client: .init(name: "t", build: "1"), proof: LinkProof.proof(secret: Data(count: 32), nonce: "x")))
            return client.next()
        }
        #expect(answer == .bye(.auth))
        #expect(!host.linked)
    }

    @Test func anotherMajorVersionIsRefused() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        let secret = host.secret
        let client = try #require(await off { TestClient(path: path) })
        defer { client.close() }
        let answer: LinkMessage? = await off {
            guard case .challenge(let nonce)? = client.next() else { return nil }
            client.send(.hello(proto: .init(major: 2, minor: 0), client: .init(name: "t", build: "1"), proof: LinkProof.proof(secret: secret, nonce: nonce)))
            return client.next()
        }
        #expect(answer == .bye(.version))
    }

    @Test func aProcessNotMatchingTheRequirementIsClosedWithoutAWord() async throws {
        let host = try Self.wake(#"identifier "dev.kore.nobody" and anchor apple generic"#)
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        let closed = await off { () -> Bool in
            guard let client = TestClient(path: path) else { return true }
            defer { client.close() }
            return client.next() == nil
        }
        #expect(closed)
    }

    @Test func oneClientAtATime() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        let path = host.socketPath
        let second = await off { () -> LinkMessage? in
            guard let other = TestClient(path: path) else { return nil }
            defer { other.close() }
            return other.next()
        }
        #expect(second == nil)
        #expect(host.linked)
    }

    @Test func commandsGetResultsAndUnknownOnesAreInvalid() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        let results: [LinkMessage.Result] = await off {
            client.send(.cmd(id: "a", .setMode(chatId: "no-such-chat", modeId: "auto")))
            client.send(.cmd(id: "b", .unknown("files.read")))
            var out: [LinkMessage.Result] = []
            while out.count < 2, let m = client.next(where: { if case .result = $0 { true } else { false } }) {
                if case .result(let r) = m { out.append(r) }
            }
            return out
        }
        #expect(results.map(\.id) == ["a", "b"])
        #expect(results.map(\.code) == [.goneChat, .invalid])
    }

    @Test func aFloodIsRateLimitedThenDropped() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        let (limited, bye): (Bool, LinkMessage?) = await off {
            for i in 0..<400 { client.send(.cmd(id: "\(i)", .stop(chatId: "x"))) }
            var limited = false
            var bye: LinkMessage?
            while let m = client.next() {
                if case .result(let r) = m, r.code == .rateLimited { limited = true }
                if case .bye = m {
                    bye = m
                    break
                }
            }
            return (limited, bye)
        }
        #expect(limited)
        #expect(bye == .bye(.rateLimited))
        #expect(LinkHost.current == nil)
        LinkRun.current?.revoke()
    }

    @Test func anOversizedFrameEndsTheLink() async throws {
        let host = try Self.wake()
        let path = host.socketPath
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        await off {
            var length = UInt32(LinkFrame.inboundMax + 1).bigEndian
            client.sendRaw(Data(bytes: &length, count: 4))
        }
        for _ in 0..<50 where LinkHost.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(LinkHost.current == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        LinkRun.current?.revoke()
    }

    @Test func disconnectSendsByeAndLeavesNoSocket() async throws {
        let host = try Self.wake()
        let path = host.socketPath
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        // Disconnect in Kore: the connection and the run's allowance both end.
        try #require(LinkRun.current).revoke()
        let bye = await off { client.next(where: { if case .bye = $0 { true } else { false } }) }
        #expect(bye == .bye(.disconnected))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(LinkRun.current == nil)
    }

    @Test func aStaleSocketIsRemovedAtTheNextWake() async throws {
        let directory = Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("old.sock").path
        FileManager.default.createFile(atPath: stale, contents: Data())
        let own = try #require(LinkIdentity.ownRequirement())
        let host = try LinkHost.wake(name: "t", requirement: own.0, directory: directory)
        defer { LinkRun.current?.revoke() }
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(FileManager.default.fileExists(atPath: host.socketPath))
    }

    @Test func aDropEndsTheConnectionAndTheRunStaysAllowedAsleep() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        let (client, _) = try await Self.link(host)
        client.close()
        for _ in 0..<50 where LinkHost.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        // Allowed but not connected: no socket, no taps, no tick, no mark.
        #expect(LinkHost.current == nil)
        #expect(LinkRun.current != nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!LinkTaps.on)
        #expect(LinkTaps.event == nil)
        #expect(Workspace.all.allObjects.allSatisfy { $0.linkMark == nil })
        #expect(LinkTaps.slash != nil)
    }

    @Test func aByeEndsTheConnectionAtOnce() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        await off { client.send(.bye(.quit)) }
        for _ in 0..<50 where LinkHost.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(LinkHost.current == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(LinkRun.current != nil)
    }

    @Test func aSocketNobodyConnectsToIsRemoved() async throws {
        let saved = LinkHost.connectWithin
        LinkHost.connectWithin = 0.3
        defer { LinkHost.connectWithin = saved }
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let path = host.socketPath
        for _ in 0..<100 where LinkHost.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(LinkHost.current == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The allowed companion's re-ring proof, now.
    static func proof(_ run: LinkRun, at ts: Int = Int(Date().timeIntervalSince1970)) -> (String, Int) {
        (LinkProof.ringProof(runSecret: run.runSecret, epoch: LinkRun.epoch, ts: ts), ts)
    }

    @Test func aReRingWithAProofReconnectsWithoutACard() async throws {
        let token = try #require(Self.ownToken())
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let run = try #require(LinkRun.current)
        let (client, first) = try await Self.link(host)
        client.close()
        for _ in 0..<50 where LinkHost.current != nil { try await Task.sleep(for: .milliseconds(20)) }
        let (proof, ts) = Self.proof(run)
        let answer = LinkDoorbell.rering(token: token, proof: proof, ts: ts, directory: Self.directory())
        guard case .allowed(let socket, let secret, let runSecret)? = answer else {
            Issue.record("expected allowed, got \(String(describing: answer))")
            return
        }
        #expect(runSecret == nil)
        #expect(secret != host.secret)
        #expect(!LinkPanel.cardOpen)
        let again = try #require(LinkHost.current)
        #expect(again.socketPath == socket)
        let (client2, second) = try await Self.link(again)
        defer { client2.close() }
        #expect(second.epoch == first.epoch)
        #expect(again.linked)
    }

    @Test func aValidProofWithoutAnAuditTokenIsAdmitted() throws {
        _ = try Self.wake()
        defer { LinkRun.current?.revoke() }
        LinkHost.current?.end(.disconnected)
        let run = try #require(LinkRun.current)
        let (proof, ts) = Self.proof(run)
        guard case .allowed? = LinkDoorbell.rering(token: nil, proof: proof, ts: ts, directory: Self.directory()) else {
            Issue.record("a valid proof alone should admit the re-ring")
            return
        }
    }

    @Test func aReplayedProofIsRefused() throws {
        _ = try Self.wake()
        defer { LinkRun.current?.revoke() }
        LinkHost.current?.end(.disconnected)
        let run = try #require(LinkRun.current)
        let (proof, ts) = Self.proof(run)
        #expect(LinkDoorbell.rering(token: nil, proof: proof, ts: ts, directory: Self.directory()) != nil)
        LinkHost.current?.end(.disconnected)
        #expect(LinkDoorbell.rering(token: nil, proof: proof, ts: ts, directory: Self.directory()) == nil)
    }

    @Test func aStaleOrWrongProofIsRefused() throws {
        _ = try Self.wake()
        defer { LinkRun.current?.revoke() }
        LinkHost.current?.end(.disconnected)
        let run = try #require(LinkRun.current)
        let now = Int(Date().timeIntervalSince1970)
        let stale = Self.proof(run, at: now - 31)
        #expect(LinkDoorbell.rering(token: nil, proof: stale.0, ts: stale.1, directory: Self.directory()) == nil)
        let wrong = LinkProof.ringProof(runSecret: Data(count: 32), epoch: LinkRun.epoch, ts: now)
        #expect(LinkDoorbell.rering(token: nil, proof: wrong, ts: now, directory: Self.directory()) == nil)
        #expect(LinkDoorbell.rering(token: nil, proof: nil, ts: nil, directory: Self.directory()) == nil)
        #expect(LinkHost.current == nil)
    }

    @Test func aProofAfterDisconnectIsRefused() throws {
        _ = try Self.wake()
        let run = try #require(LinkRun.current)
        let (proof, ts) = Self.proof(run)
        run.revoke()
        #expect(LinkRun.current == nil)
        #expect(LinkTaps.slash == nil)
        #expect(LinkDoorbell.rering(token: nil, proof: proof, ts: ts, directory: Self.directory()) == nil)
    }

    @Test func aReRingFromADifferentRequirementIsRefused() throws {
        let token = try #require(Self.ownToken())
        _ = try Self.wake(#"identifier "dev.kore.nobody" and anchor apple generic"#)
        defer { LinkRun.current?.revoke() }
        LinkHost.current?.end(.disconnected)
        let run = try #require(LinkRun.current)
        let (proof, ts) = Self.proof(run)
        // The proof is right, but this process isn't what was pinned.
        #expect(LinkDoorbell.rering(token: token, proof: proof, ts: ts, directory: Self.directory()) == nil)
    }

    @Test func theCompanionsCommandsAreListedSafeAndSent() async throws {
        let host = try Self.wake()
        defer { LinkRun.current?.revoke() }
        let run = try #require(LinkRun.current)
        let offered = (1...8).map { LinkMessage.CompanionCommand(id: "c\($0)", label: "Command \($0)") }
            + [.init(id: "bad", label: "two\nlines and a very long label that goes on and on")]
        let (client, _) = try await Self.link(host, commands: [.init(id: "x", label: "Show\u{7}\nQR")] + offered)
        defer { client.close() }
        #expect(run.commands.count == 6)
        #expect(run.commands.first == .init(id: "x", label: "ShowQR"))
        let entries = run.slashEntries()
        #expect(entries.compactMap(\.title) == run.commands.map(\.label) + ["Disconnect Test companion"])
        LinkTaps.slashChosen?(LinkRun.commandPrefix + "x")
        let told = await off { client.next(where: { if case .command = $0 { true } else { false } }) }
        #expect(told == .command(id: "x"))
        // An id it didn't offer is never sent.
        LinkTaps.slashChosen?(LinkRun.commandPrefix + "c8")
        #expect(await off { client.next(where: { if case .command = $0 { true } else { false } }) } == nil)
    }

    @Test func openRelaunchesTheCompanionWhileItIsNotConnected() async throws {
        let own = try #require(LinkIdentity.ownRequirement())
        let app = URL(fileURLWithPath: "/Applications/Stub Companion.app")
        let run = LinkRun.allow(name: "Stub", requirement: own.0, key: own.1, appURL: app)
        defer { run.revoke() }
        var opened: URL?
        let saved = LinkRun.opener
        LinkRun.opener = { opened = $0 }
        defer { LinkRun.opener = saved }
        let titles = run.slashEntries().compactMap(\.title)
        #expect(titles == ["Open Stub", "Disconnect Stub"])
        LinkTaps.slashChosen?(LinkRun.openName)
        #expect(opened == app)
        LinkTaps.slashChosen?(LinkRun.disconnectName)
        #expect(LinkRun.current == nil)
    }

    @Test func nothingIsInSlashBeforeTheFirstAllow() {
        LinkRun.current?.revoke()
        #expect(LinkTaps.slash == nil)
        #expect(LinkTaps.slashChosen == nil)
        #expect(SlashCommand.matches([], sigil: "/", query: "", link: LinkTaps.slash?() ?? []).allSatisfy { !$0.name.hasPrefix("link-") })
    }
}

/// The doorbell's Apple Event, built here with this process's own audit token: who rang is read
/// from the event's sender attribute, and the immediate answers fill the reply.
extension LinkHostTests {
    static func ownToken() -> Data? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    static func ring(token: Data?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: 0x4B6F_5265, eventID: 0x7269_6E67, targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "Event companion"), forKeyword: keyDirectObject)
        if let token { event.setAttribute(NSAppleEventDescriptor(descriptorType: typeData, data: token)!, forKeyword: 0x746F_6B6E) }
        return event
    }

    static func answer(_ reply: NSAppleEventDescriptor) -> (Int32?, String?) {
        (reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue)
    }

    @Test func aRingWithoutASenderIsInvalid() {
        let reply = NSAppleEventDescriptor.record()
        LinkDoorbell.ring(Self.ring(token: nil), reply)
        #expect(Self.answer(reply) == (-1743, "invalid"))
        let direct = NSAppleEventDescriptor.record()
        LinkDoorbell.ring(name: "x", token: Data(count: 32), reply: direct)
        #expect(Self.answer(direct) == (-1743, "invalid"))
    }

    @Test func aRingWhileLinkedIsBusy() async throws {
        let token = try #require(Self.ownToken())
        let host = try LinkHostTests.wake()
        defer { LinkRun.current?.revoke() }
        let (client, _) = try await Self.link(host)
        defer { client.close() }
        let reply = NSAppleEventDescriptor.record()
        LinkDoorbell.ring(name: "Event companion", token: token, reply: reply)
        #expect(Self.answer(reply) == (-1743, "busy"))
        #expect(LinkHost.current === host)
    }

    @Test func theSenderIsReadFromItsAuditToken() throws {
        let token = try #require(Self.ownToken())
        let fromToken = try #require(LinkIdentity.requirement(auditToken: token))
        let own = try #require(LinkIdentity.ownRequirement())
        #expect(fromToken.1 == own.1)
    }
}
