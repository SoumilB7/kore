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
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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

    @Test func aProcessGoneOnTheWayIsntExternal() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
        #expect(AgentCaller.chain(of: 500, parent: { parents[$0] }) == [500, 400, 300])
        let broken: [pid_t: pid_t] = [500: 400]
        #expect(AgentCaller.chain(of: 500, parent: { broken[$0] }) == nil)
        #expect(AgentCaller.chain(of: 500, parent: { _ in nil }) == nil)
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
        #expect(AgentCommand.allowed(.own).map(\.name) == AgentCommand.all.map(\.name))
        // Watch reads; every change is Own's.
        #expect(AgentCommand.allowed(.watch).allSatisfy { !$0.name.hasPrefix("chat.") || $0.name == "chat.show" })
        #expect(AgentCommand.allowed(.watch).count == 9)
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

@Suite("agent secrets")
struct AgentSecretsTests {
    // Built here so that nothing in the repository looks like a key to a scanner.
    static let tail = String(repeating: "a1B2c3D4", count: 5)

    static let shapes: [String] = {
        var out: [String] = []
        out.append("sk-" + tail)
        out.append("sk-ant-api03-" + tail)
        out.append("sk_" + "live_" + tail)
        out.append("gh" + "p_" + tail)
        out.append("github" + "_pat_" + tail)
        out.append("AKIA" + "IOSFODNN7EXAMPLE")
        out.append("xox" + "b-1234-" + tail)
        out.append("AIza" + tail)
        out.append("glpat-" + tail)
        out.append("npm_" + tail)
        out.append("hf_" + tail)
        out.append("eyJ" + tail + ".eyJ" + tail + "." + tail)
        return out
    }()

    @Test(arguments: shapes)
    func keysAreMasked(_ key: String) {
        let out = AgentSecrets.mask("before \(key) after")
        #expect(out == "before \(AgentSecrets.mask) after")
    }

    struct Line: Codable, Equatable {
        var a: String
        var b: String
    }

    /// A line as the channel encodes it: masked, and still valid JSON with its fields apart.
    func encoded(_ a: String, _ b: String = "next") throws -> Line {
        try JSONDecoder().decode(Line.self, from: AgentChannel.encode(Line(a: a, b: b)))
    }

    @Test(arguments: shapes)
    func keysAreMaskedInALine(_ key: String) throws {
        #expect(try encoded("before \(key) after") == Line(a: "before \(AgentSecrets.mask) after", b: "next"))
    }

    /// In a line, a key right after an escape has no word boundary before it.
    @Test(arguments: ["\n", "\t", "\r", "\u{08}", "\u{0C}", "\u{07}"])
    func aKeyAfterAnEscapeIsMasked(_ escape: String) throws {
        for key in Self.shapes {
            #expect(try encoded("before\(escape)\(key)\(escape)after").a == "before\(escape)\(AgentSecrets.mask)\(escape)after")
        }
        #expect(try encoded("x\(escape)Bearer " + Self.tail).a == "x\(escape)Bearer \(AgentSecrets.mask)")
        #expect(try encoded("x\(escape)postgres://me:abcdefgh@db").a == "x\(escape)postgres://me:\(AgentSecrets.mask)@db")
        #expect(try encoded("password:\(["\u{07}", "\u{08}"].contains(escape) ? " " : escape)abcdefgh1234").a.hasSuffix(AgentSecrets.mask))
    }

    static let longRuns: [String] = [
        "echo " + String(repeating: "a", count: 200 * 1024),
        "echo " + String(repeating: "-eyJ", count: 64 * 1024),
    ]

    @Test(arguments: longRuns)
    func maskingStaysQuickOnALongRun(_ run: String) {
        let began = ContinuousClock.now
        #expect(AgentSecrets.mask(run) == run)
        // Quadratic, these took minutes; a debug build on a busy machine has plenty of room.
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func maskingKeepsALineValid() throws {
        // Named values, quoted and on lines of their own.
        #expect(try encoded("{\"api_key\": \"abcdefgh1234\"}").a == "{\"api_key\": \"\(AgentSecrets.mask)\"}")
        #expect(try encoded("line\nAPI_KEY=abcdefgh1234\nline").a == "line\nAPI_KEY=\(AgentSecrets.mask)\nline")
        // A private key cut off by a cap: masked to the string's end, the next field untouched.
        let cut = "-----BEGIN RSA PRIVATE " + "KEY-----\nabc\ndef"
        #expect(try encoded("a \(cut)", "kept") == Line(a: "a \(AgentSecrets.mask)", b: "kept"))
        // What only looks like one across two fields stays as it is.
        #expect(try encoded("https://me:", "pass@host") == Line(a: "https://me:", b: "pass@host"))
        #expect(try encoded("password", "abcdefgh1234") == Line(a: "password", b: "abcdefgh1234"))
    }

    @Test func aPrivateKeyIsMaskedToItsEndOrTheEndOfTheText() {
        let body = "-----BEGIN RSA PRIVATE " + "KEY-----\nabc\ndef\n"
        #expect(AgentSecrets.mask("a \(body)-----END RSA PRIVATE KEY----- b") == "a \(AgentSecrets.mask) b")
        #expect(AgentSecrets.mask("a \(body)") == "a \(AgentSecrets.mask)")
    }

    @Test func aNamedValueKeepsItsName() {
        #expect(AgentSecrets.mask("API_KEY=abcdefgh1234") == "API_KEY=\(AgentSecrets.mask)")
        #expect(AgentSecrets.mask("\"client_secret\": \"abcdefgh1234\"") == "\"client_secret\": \"\(AgentSecrets.mask)\"")
        #expect(AgentSecrets.mask("password: abcdefgh") == "password: \(AgentSecrets.mask)")
        #expect(AgentSecrets.mask("Authorization: Bearer " + Self.tail) == "Authorization: Bearer \(AgentSecrets.mask)")
        #expect(AgentSecrets.mask("postgres://me:abcdefgh@db/x") == "postgres://me:\(AgentSecrets.mask)@db/x")
    }

    static let ordinary: [String] = [
        "1A2B3C4D-0000-0000-0000-000000000001", "8d4f6bc2e1a94f0b8d4f6bc2e1a94f0b8d4f6bc2", "the task-management-and-risk-assessment-framework",
        "input_tokens: 12345678", "password: short", "see the secret plan", "https://example.com:8080/path", "/Users/me/src/app.swift:12",
    ]

    @Test(arguments: ordinary)
    func ordinaryTextIsLeftAlone(_ text: String) {
        #expect(AgentSecrets.mask(text) == text)
    }
}

@Suite("agent connection")
struct AgentConnectionTests {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var moved = 0
        var lines = 0
        func moved(_ note: Void) { lock.withLock { moved += 1 } }
    }

    /// A connection on one end of a socket pair whose peer token is `now`, not what it was made with.
    func connection(_ seen: Seen, token now: Data) -> (AgentConnection, Int32) {
        var pair: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = AgentConnection(
            fd: pair[0], queue: DispatchQueue(label: "agent-connection-test"), token: Data([1]), peerToken: { _ in now },
            onLines: { _ in seen.lock.withLock { seen.lines += 1 } }, onMoved: { seen.moved(()) }, onClose: {}, onGone: {})
        connection.start()
        return (connection, pair[1])
    }

    func settled(_ seen: Seen, _ wanted: @Sendable (Seen) -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if seen.lock.withLock({ wanted(seen) }) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func anotherProcessSendingIsNoticed() async throws {
        let seen = Seen()
        let (connection, other) = connection(seen, token: Data([2]))
        defer {
            connection.finish()
            Darwin.close(other)
        }
        _ = write(other, "x\n", 2)
        #expect(try await settled(seen) { $0.moved == 1 && $0.lines == 0 })
    }

    @Test func anotherProcessOnlyReadingIsNoticedWhenKoreSends() async throws {
        let seen = Seen()
        let (connection, other) = connection(seen, token: Data([2]))
        defer {
            connection.finish()
            Darwin.close(other)
        }
        // A follower's events: told once, and nothing goes out to it.
        connection.send { Data("{}".utf8) }
        connection.send { Data("{}".utf8) }
        #expect(try await settled(seen) { $0.moved == 1 })
        var byte: UInt8 = 0
        _ = fcntl(other, F_SETFL, fcntl(other, F_GETFL) | O_NONBLOCK)
        #expect(read(other, &byte, 1) < 0)
    }

    @Test func theSameProcessGoesOn() async throws {
        let seen = Seen()
        let (connection, other) = connection(seen, token: Data([1]))
        defer {
            connection.finish()
            Darwin.close(other)
        }
        _ = write(other, "x\n", 2)
        #expect(try await settled(seen) { $0.lines == 1 && $0.moved == 0 })
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
        // A socket file with nobody listening, as a killed Kore leaves one.
        let left = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(left, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0)
        Darwin.close(left)
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

    @Test func whatIsntItsOwnIsLeftAlone() throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        let path = Self.socket(directory)
        let manager = FileManager.default
        // A file at the socket's path: not opened over, not removed.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(manager.createFile(atPath: path, contents: Data("mine".utf8)))
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        #expect(AgentChannel.current == nil)
        #expect(manager.contents(atPath: path) == Data("mine".utf8))
        AgentGrants.stopAll()
        try manager.removeItem(atPath: path)
        // Replaced after opening: closing leaves what's there now.
        AgentGrants.setExternal(.watch)
        #expect(AgentChannel.current != nil)
        try manager.removeItem(atPath: path)
        #expect(manager.createFile(atPath: path, contents: Data("mine".utf8)))
        AgentGrants.stopAll()
        #expect(manager.contents(atPath: path) == Data("mine".utf8))
        try manager.removeItem(atPath: path)
        // The folder a link to another: refused, and the other's mode is as it was.
        let other = directory.deletingLastPathComponent().appendingPathComponent("kat-other-\(UUID().uuidString.prefix(8))")
        try manager.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? manager.removeItem(at: other) }
        try manager.removeItem(at: directory)
        try manager.createSymbolicLink(at: directory, withDestinationURL: other)
        defer { try? manager.removeItem(at: directory) }
        AgentGrants.setExternal(.watch)
        #expect(AgentChannel.current == nil)
        #expect((try manager.attributesOfItem(atPath: other.path))[.posixPermissions] as? Int == 0o755)
        #expect(!manager.fileExists(atPath: other.appendingPathComponent(AgentChannel.socketName).path))
    }

    @Test func theSwitchOffEndsExternalAccessToo() {
        _ = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        #expect(AgentChannel.current != nil)
        AgentGrants.setEnabled(false)
        #expect(AgentGrants.external == .off && AgentChannel.current == nil)
        AgentGrants.setEnabled(true)
        #expect(AgentChannel.current == nil)
    }

    @Test func aFloodEndsItsConnection() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        // Bad lines count like commands: after the budget and the strikes, the connection ends.
        let limit = AgentChannel.perMinute + AgentChannel.strikes
        let (answered, bye): (Int, AgentLine?) = await off {
            guard let client = AgentTestClient(path: path) else { return (0, nil) }
            defer { client.close() }
            _ = client.hello()
            var answers = 0
            var last: AgentLine?
            for _ in 0..<limit + 1 {
                client.send(["type": 1])
                last = client.next()
                if last?["type"] as? String != "result" { break }
                answers += 1
            }
            return (answers, last)
        }
        #expect(answered == limit)
        #expect(bye?["type"] as? String == "bye" && bye?["code"] as? String == "rate_limited")
    }

    @Test func oneProcessCantHoldEveryPlace() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        let held = AgentSlots.perProcess
        let (kept, told): (Int, [String]) = await off {
            let clients = (0..<held + 3).compactMap { _ in AgentTestClient(path: path) }
            defer { clients.forEach { $0.close() } }
            var told: [String] = []
            var kept = 0
            for client in clients {
                var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(client.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                if let bye = client.next() { told.append(bye["code"] as? String ?? "?") } else { kept += 1 }
            }
            return (kept, told)
        }
        // The rest are told why, not just closed.
        #expect(kept == held && told == ["rate_limited", "rate_limited", "rate_limited"])
    }

    @Test func aClosedConnectionIsFreed() async throws {
        let directory = Self.reset()
        defer { AgentGrants.stopAll() }
        AgentGrants.setEnabled(true)
        AgentGrants.setExternal(.watch)
        let path = Self.socket(directory)
        let client = try #require(await off { AgentTestClient(path: path) })
        #expect(await off { client.hello() }?["type"] as? String == "welcome")
        weak let connection = AgentChannel.current?.newestConnection
        #expect(connection != nil)
        // A line that never ends, then gone.
        await off {
            client.send(["type": String(repeating: "a", count: 1024)])
            let part = Data(repeating: 0x61, count: 32 * 1024)
            _ = part.withUnsafeBytes { write(client.fd, $0.baseAddress, $0.count) }
            client.close()
        }
        for _ in 0..<100 where connection != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(connection == nil && AgentChannel.current?.connections == 0)
    }

    @Test func rootsProcessesAreReadable() {
        // launchd is root's: the full record would refuse this, and a Terminal's `login` with it.
        #expect(AgentCaller.parent(of: 1) != nil)
        #expect(AgentCaller.parent(of: getpid()) == getppid())
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
