import Darwin
import Foundation
import KoreCore
import Testing

@testable import KoreLink
@testable import KoreUI

/// One line from Kore, parsed (read on the client's thread, checked on the main actor).
struct AgentLine: @unchecked Sendable {
    let object: [String: Any]
    subscript(key: String) -> Any? { object[key] }
}

/// A caller on the agent channel: lines of JSON, blocking reads with a timeout.
final class AgentTestClient: @unchecked Sendable {
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

    func send(_ object: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The next line, or nil when the socket closed or nothing came in time.
    func next() -> AgentLine? {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return ((try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]).map(AgentLine.init)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func hello(pass: String? = nil) -> AgentLine? {
        var hello: [String: Any] = ["type": "hello", "proto": 1, "client": "test"]
        if let pass { hello["pass"] = pass }
        send(hello)
        return next()
    }

    func command(_ id: String, _ cmd: String, _ args: [String: Any] = [:]) -> AgentLine? {
        send(["type": "cmd", "id": id, "cmd": cmd, "args": args])
        return next()
    }

    func close() { Darwin.close(fd) }
}

@Suite("agent caller")
struct AgentCallerTests {
    @Test func walksUpToLaunchdAndStopsOnALoop() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
        #expect(AgentCaller.ancestors(of: 500, parent: { parents[$0] }) == [500, 400, 300])
        let loop: [pid_t: pid_t] = [7: 8, 8: 7]
        #expect(AgentCaller.ancestors(of: 7, parent: { loop[$0] }) == [7, 8])
        #expect(AgentCaller.ancestors(of: 9, parent: { $0 + 1 }).count == AgentCaller.depthMax)
    }

    @Test func passAndTreeMustAgree() {
        let clis = ["passA": pid_t(300), "passB": pid_t(310)]
        // A shell under chat A's CLI, with A's pass.
        #expect(AgentCaller.verdict(ancestors: [500, 400, 300, 200], pass: "passA", clis: clis) == .chat(pass: "passA"))
        // Under A's CLI, with B's pass, or none.
        #expect(AgentCaller.verdict(ancestors: [500, 400, 300], pass: "passB", clis: clis) == .mismatch)
        #expect(AgentCaller.verdict(ancestors: [500, 400, 300], pass: nil, clis: clis) == .mismatch)
        // A's pass outside A's tree (copied into a terminal), or a pass no running CLI has.
        #expect(AgentCaller.verdict(ancestors: [600, 200], pass: "passA", clis: clis) == .mismatch)
        #expect(AgentCaller.verdict(ancestors: [600, 200], pass: "stale", clis: clis) == .mismatch)
        // A terminal: no chat above it, no pass.
        #expect(AgentCaller.verdict(ancestors: [600, 200], pass: nil, clis: clis) == .external)
        #expect(AgentCaller.verdict(ancestors: [600, 200], pass: "", clis: clis) == .external)
        // The nearest CLI decides.
        #expect(AgentCaller.verdict(ancestors: [500, 310, 300], pass: "passB", clis: clis) == .chat(pass: "passB"))
    }
}

@Suite("agent grants and refs")
struct AgentGrantTests {
    @Test func tiersAddUpAndOffHasNothing() {
        #expect(AgentCommand.allowed(.off).isEmpty)
        #expect(AgentCommand.allowed(.watch).map(\.name) == AgentCommand.all.map(\.name))
        #expect(AgentTier.off < .watch && .watch < .own && .own < .drive && .drive < .full)
        for tier in AgentTier.allCases where tier != .off {
            #expect(AgentCommand.allowed(tier).allSatisfy { $0.tier <= tier })
        }
    }

    @Test func chatRefs() {
        let chats = [
            (id: "1A2B3C4D-0000-0000-0000-000000000001", title: "Fix login"),
            (id: "1A2B9999-0000-0000-0000-000000000002", title: "Fix login page"),
            (id: "77777777-0000-0000-0000-000000000003", title: "Release notes"),
        ]
        #expect(AgentRefs.resolve(".", chats: chats, own: chats[2].id) == .chat(chats[2].id))
        #expect(AgentRefs.resolve(".", chats: chats, own: nil) == .notInChat)
        #expect(AgentRefs.resolve("1a2b3c4d", chats: chats, own: nil) == .chat(chats[0].id))
        #expect(AgentRefs.resolve("1a2b", chats: chats, own: nil) == .ambiguous([chats[0].id, chats[1].id]))
        #expect(AgentRefs.resolve("fix login", chats: chats, own: nil) == .chat(chats[0].id))
        #expect(AgentRefs.resolve("page", chats: chats, own: nil) == .chat(chats[1].id))
        #expect(AgentRefs.resolve("fix", chats: chats, own: nil) == .ambiguous([chats[0].id, chats[1].id]))
        #expect(AgentRefs.resolve("notes", chats: chats, own: nil) == .chat(chats[2].id))
        #expect(AgentRefs.resolve("nothing", chats: chats, own: nil) == .none)
    }
}

@MainActor
@Suite("agent channel", .serialized)
struct AgentChannelTests {
    /// A fresh switch (in a defaults domain of its own), no grants, a socket folder of its own.
    static func reset() -> URL {
        AgentGrants.stopAll()
        UserDefaults.standard.removePersistentDomain(forName: "kore-agent-tests")
        AgentGrants.defaults = UserDefaults(suiteName: "kore-agent-tests")!
        let directory = URL(fileURLWithPath: "/tmp/kat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        AgentChannel.directory = directory
        return directory
    }

    static func socket(_ directory: URL) -> String { directory.appendingPathComponent(AgentChannel.socketName).path }

    @Test func socketOnlyWhileSwitchedOnWithAGrant() throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        let path = Self.socket(directory)
        // Off by default: a grant opens nothing.
        #expect(!AgentGrants.enabled)
        AgentGrants.set(.watch, chat: "chat-1")
        #expect(AgentChannel.current == nil && !FileManager.default.fileExists(atPath: path))
        // On, with the grant: the socket, private.
        AgentGrants.setEnabled(true)
        #expect(AgentChannel.current != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        // The last grant off: closed.
        AgentGrants.set(.off, chat: "chat-1")
        #expect(AgentChannel.current == nil && !FileManager.default.fileExists(atPath: path))
        // On with no grant: nothing.
        AgentGrants.setEnabled(true)
        #expect(AgentChannel.current == nil)
        // Stop all closes it at once; the switch off clears the grants.
        AgentGrants.set(.drive, chat: "chat-2")
        #expect(AgentChannel.current != nil)
        AgentGrants.stopAll()
        #expect(AgentChannel.current == nil && AgentGrants.tiers.isEmpty && !FileManager.default.fileExists(atPath: path))
        AgentGrants.set(.watch, chat: "chat-3")
        AgentGrants.setEnabled(false)
        #expect(AgentChannel.current == nil && AgentGrants.tiers.isEmpty)
    }

    @Test func aGrantWhoseChatClosedCountsNoMore() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        // No window holds this chat: the first caller finds the grant gone, and the socket goes.
        AgentGrants.set(.watch, chat: "closed-chat")
        #expect(AgentChannel.current != nil)
        let path = Self.socket(directory)
        let answer: AgentLine? = await off {
            guard let client = AgentTestClient(path: path) else { return nil }
            defer { client.close() }
            return client.hello()
        }
        #expect(answer == nil)
        #expect(AgentChannel.current == nil && AgentGrants.tiers.isEmpty && !FileManager.default.fileExists(atPath: path))
    }

    @Test func externalCallersOnlyThroughTheSeam() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        let path = Self.socket(directory)
        AgentGrants.setExternal(.watch)
        let (welcome, caps, raise): (AgentLine?, AgentLine?, AgentLine?) = await off {
            guard let client = AgentTestClient(path: path) else { return (nil, nil, nil) }
            defer { client.close() }
            return (client.hello(), client.command("1", "agent.caps"), client.command("2", "chat.send"))
        }
        #expect(welcome?["type"] as? String == "welcome")
        #expect((welcome?["caller"] as? [String: Any])?["class"] as? String == "external")
        #expect(welcome?["tier"] as? String == "watch")
        #expect((caps?["data"] as? [String: Any])?["commands"] as? [String] == AgentCommand.allowed(.watch).map(\.name))
        #expect(raise?["ok"] as? Bool == false && raise?["code"] as? String == "unknown_command")
    }

    @Test func aPassMustMatchTheTreeItRunsIn() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        // This test process runs under its parent, recorded here as a chat's CLI.
        let pass = AgentPasses.make()
        AgentPasses.shared.register(pass, pid: getppid())
        defer { AgentPasses.shared.ended(getppid()) }
        let (none, wrong, right): (AgentLine?, AgentLine?, AgentLine?) = await off {
            func hello(_ pass: String?) -> AgentLine? {
                guard let client = AgentTestClient(path: path) else { return nil }
                defer { client.close() }
                return client.hello(pass: pass)
            }
            return (hello(nil), hello(AgentPasses.make()), hello(pass))
        }
        // In a chat's tree, with no pass or another one: refused even though external may watch.
        #expect(none?["code"] as? String == "mismatch")
        #expect(wrong?["code"] as? String == "mismatch")
        // The right pass, but no open chat has it.
        #expect(right?["code"] as? String == "denied")
    }

    @Test func aCommandAboveTheTierIsRefused() async throws {
        let directory = Self.reset()
        defer {
            AgentChannel.commands = AgentCommand.all
            AgentGrants.stopAll()
        }
        let drive = AgentCommand(name: "test.drive", tier: .drive)
        AgentChannel.commands = AgentCommand.all + [drive]
        #expect(AgentCommand.refusal("test.drive", tier: .watch, among: AgentChannel.commands) == .tier)
        #expect(AgentCommand.refusal("test.drive", tier: .own, among: AgentChannel.commands) == .tier)
        #expect(AgentCommand.refusal("test.drive", tier: .drive, among: AgentChannel.commands) == nil)
        #expect(AgentCommand.refusal("test.drive", tier: .full, among: AgentChannel.commands) == nil)
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        let (above, still): (AgentLine?, AgentLine?) = await off {
            guard let client = AgentTestClient(path: path) else { return (nil, nil) }
            defer { client.close() }
            _ = client.hello()
            return (client.command("1", "test.drive"), client.command("2", "agent.whoami"))
        }
        #expect(above?["ok"] as? Bool == false && above?["code"] as? String == "tier")
        #expect(above?["message"] as? String == AgentChannel.message(.tier))
        // Refused, not cut off: the same connection goes on.
        #expect(still?["ok"] as? Bool == true)
    }

    @Test func aSocketLeftByAKilledKoreIsReplaced() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        let path = Self.socket(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A file at the socket's path, as a killed Kore leaves one.
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        #expect(AgentChannel.current != nil)
        let welcome: AgentLine? = await off {
            guard let client = AgentTestClient(path: path) else { return nil }
            defer { client.close() }
            return client.hello()
        }
        #expect(welcome?["type"] as? String == "welcome")
    }

    @Test func thirtyCommandsAMinute() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        let limit = AgentChannel.perMinute
        let codes: [String] = await off {
            guard let client = AgentTestClient(path: path) else { return [] }
            defer { client.close() }
            _ = client.hello()
            return (1...limit + 1).map { i in
                let result = client.command("\(i)", "agent.whoami")
                return result?["ok"] as? Bool == true ? "ok" : result?["code"] as? String ?? "none"
            }
        }
        #expect(codes.count == AgentChannel.perMinute + 1)
        #expect(codes.dropLast().allSatisfy { $0 == "ok" })
        #expect(codes.last == "rate_limited")
    }

    @Test func stopAllEndsConnectedCallers() async throws {
        let directory = Self.reset()
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        let client = try #require(await off { AgentTestClient(path: path) })
        defer { client.close() }
        let welcome = await off { client.hello() }
        #expect(welcome?["type"] as? String == "welcome")
        AgentGrants.stopAll()
        let bye = await off { client.next() }
        #expect(bye?["type"] as? String == "bye" && bye?["code"] as? String == "stopped")
        #expect(AgentChannel.current == nil)
    }
}
