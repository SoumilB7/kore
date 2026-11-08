import Foundation
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// Link 1.8's terminals through a kore-host on this Mac: a shell's round trip, its size, its
/// exit, a reattach's replay, the cap, and what's refused.
@Suite("kore-host terminals", .serialized)
@MainActor
struct TerminalTests {
    /// A daemon with a full grant's client on it; shells start in `sh` with the rig's own home.
    @MainActor private final class Rig {
        let rig: HostRig
        let store: GrantStore
        var client: Client!
        var grant: Grant!

        init() throws {
            rig = try HostRig()
            try rig.host.start()
            rig.host.terminals.base = ["HOME": rig.root.path, "PATH": "/usr/bin:/bin", "PS1": "$ "]
            store = GrantStore(rig.paths.grants)
        }

        func connect(_ name: String = "mac", control: GrantControl = .full) async throws {
            grant = try store.load(name) ?? store.allow(name, control: control, socket: rig.paths.socket)
            client = try Client(rig.paths.socket)
            try await until { !self.client.got.isEmpty }
            client.hello(grant: grant)
            try await until { self.client.got.count >= 3 }
        }

        func send<T: Encodable>(_ value: T) { client.socket.send(StreamWire.encode(value)) }

        func results() -> [PtyResult] {
            client.raws.filter { StreamWire.type($0) == "result" }.compactMap { try? JSONDecoder().decode(PtyResult.self, from: $0) }
        }

        func result(_ id: String) async throws -> PtyResult {
            try await until { self.results().contains { $0.id == id } }
            return results().first { $0.id == id }!
        }

        func outputs(_ ptyId: String) -> [PtyOutput] {
            client.raws.filter { StreamWire.type($0) == PtyOutput.type }.compactMap { try? JSONDecoder().decode(PtyOutput.self, from: $0) }
                .filter { $0.ptyId == ptyId }
        }

        func text(_ ptyId: String) -> String {
            String(decoding: outputs(ptyId).compactMap(\.bytes).reduce(Data(), +), as: UTF8.self)
        }

        func open(_ id: String, cols: Int = 80, rows: Int = 24) async throws -> String {
            send(PtyOpen(id: id, cwd: rig.folder.path, cols: cols, rows: rows, shell: "/bin/sh"))
            let result = try await result(id)
            #expect(result.ok, "\(result.message ?? "")")
            return result.ptyId ?? ""
        }

        func type(_ ptyId: String, _ text: String) { send(PtyInput(ptyId: ptyId, data: Data(text.utf8))) }

        func finish() { rig.finish() }
    }

    @Test func aShellEchoesResizesAndSaysItsExit() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        let pty = try await rig.open("o1")
        #expect(rig.results().first?.shell == "sh")
        rig.type(pty, "echo h''i\r")
        try await until { rig.text(pty).contains("hi\r\n") }
        // It started in the served folder.
        rig.type(pty, "pwd\r")
        try await until { rig.text(pty).contains("/work\r\n") }
        rig.send(PtyResize(ptyId: pty, cols: 101, rows: 33))
        rig.type(pty, "stty size\r")
        try await until { rig.text(pty).contains("33 101") }
        // Each output frame starts where the last ended.
        let outputs = rig.outputs(pty)
        for (a, b) in zip(outputs, outputs.dropFirst()) { #expect(b.seq == a.seq + Int64(a.bytes?.count ?? 0)) }
        rig.type(pty, "exit 3\r")
        try await until { rig.client.raws.contains { StreamWire.type($0) == PtyExit.type } }
        let exit = rig.client.raws.first { StreamWire.type($0) == PtyExit.type }.flatMap { try? JSONDecoder().decode(PtyExit.self, from: $0) }
        #expect(exit == PtyExit(ptyId: pty, code: 3))
        try await until { rig.rig.host.terminals.count == 0 }
    }

    @Test func aReattachReplaysWhatTheShellWroteMeanwhile() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        let pty = try await rig.open("o1")
        rig.type(pty, "echo fir''st\r")
        try await until { rig.text(pty).contains("first\r\n") }
        let stood = rig.outputs(pty).last.map { $0.seq + Int64($0.bytes?.count ?? 0) } ?? 0
        // The link drops; the shell runs on and writes meanwhile.
        rig.type(pty, "sleep 0.3; echo sec''ond\r")
        try await until { !rig.text(pty).isEmpty }
        rig.client.socket.close()
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.rig.host.terminals.count == 1)

        // From where this client stood: only what it missed, no reset.
        try await rig.connect()
        rig.send(PtyAttach(id: "a1", ptyId: pty, after: stood))
        #expect(try await rig.result("a1").ok)
        try await until { rig.text(pty).contains("second\r\n") }
        #expect(rig.outputs(pty).first?.reset == nil)
        #expect(rig.outputs(pty).first?.seq == stood)
        #expect(!rig.text(pty).contains("first\r\n"))

        // A client with nothing: the whole scrollback, as a reset.
        rig.client.socket.close()
        try await rig.connect()
        rig.send(PtyAttach(id: "a2", ptyId: pty, after: nil, cols: 90, rows: 20))
        #expect(try await rig.result("a2").ok)
        try await until { rig.text(pty).contains("second\r\n") }
        #expect(rig.outputs(pty).first?.reset == true)
        #expect(rig.text(pty).contains("first\r\n"))
        rig.type(pty, "stty size\r")
        try await until { rig.text(pty).contains("20 90") }

        // A pty the box doesn't have.
        rig.send(PtyAttach(id: "a3", ptyId: "pnope", after: 0))
        #expect(try await rig.result("a3").gone == true)
        // Closed: the shell is hung up and gone.
        rig.send(PtyClose(ptyId: pty))
        try await until { rig.rig.host.terminals.count == 0 }
    }

    @Test func aGrantHoldsEightAndAShellNoClientShowsGivesWay() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        var ids: [String] = []
        for n in 0..<PtyWire.maxPerGrant { ids.append(try await rig.open("o\(n)")) }
        rig.send(PtyOpen(id: "over", cwd: rig.rig.folder.path, cols: 80, rows: 24, shell: "/bin/sh"))
        let over = try await rig.result("over")
        #expect(!over.ok)
        #expect(over.code == .busy)
        // Detached (the link went): the oldest gives way to a new one.
        rig.client.socket.close()
        try await until { rig.rig.host.terminals.count == PtyWire.maxPerGrant }
        try await rig.connect()
        _ = try await rig.open("again")
        #expect(rig.rig.host.terminals.count == PtyWire.maxPerGrant)
        rig.rig.host.terminals.stopAll()
    }

    @Test func onlyAFullGrantGetsAShellAndOnlyInAServedFolder() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect("act", control: .act)
        rig.send(PtyOpen(id: "a", cwd: rig.rig.folder.path, cols: 80, rows: 24))
        #expect(try await rig.result("a").code == .deniedControl)
        rig.client.socket.close()

        try await rig.connect()
        let outside = rig.rig.root.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: rig.rig.folder.path + "/out", withDestinationPath: outside.path)
        let asks: [(String, PtyOpen, ResultCode)] = [
            ("outside", PtyOpen(id: "outside", cwd: outside.path, cols: 80, rows: 24), .deniedPath),
            ("link", PtyOpen(id: "link", cwd: rig.rig.folder.path + "/out", cols: 80, rows: 24), .deniedPath),
            ("climb", PtyOpen(id: "climb", cwd: rig.rig.folder.path + "/../away", cols: 80, rows: 24), .deniedPath),
            ("relative", PtyOpen(id: "relative", cwd: "work", cols: 80, rows: 24), .invalid),
            ("size", PtyOpen(id: "size", cwd: rig.rig.folder.path, cols: 0, rows: 24), .invalid),
            ("shell", PtyOpen(id: "shell", cwd: rig.rig.folder.path, cols: 80, rows: 24, shell: "/usr/bin/python3"), .invalid),
        ]
        for (id, ask, code) in asks {
            rig.send(ask)
            let result = try await rig.result(id)
            #expect(!result.ok, "\(id)")
            #expect(result.code == code, "\(id)")
        }
        #expect(rig.rig.host.terminals.count == 0)
        // Another grant can't type into, size or close this one's shell.
        let pty = try await rig.open("mine")
        rig.client.socket.close()
        try await rig.connect("other")
        rig.send(PtyAttach(id: "theirs", ptyId: pty, after: 0))
        #expect(try await rig.result("theirs").gone == true)
        rig.send(PtyClose(ptyId: pty))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.rig.host.terminals.count == 1)
        rig.rig.host.terminals.stopAll()
    }
}
