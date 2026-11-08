import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// Link 1.8's git on a box: status as a map and then as changes, pushed while watched; a diff;
/// a file's text at HEAD; and refusals outside the served folders.
@Suite("kore-host git", .serialized)
@MainActor
struct BoxGitTests {
    @MainActor private final class Rig {
        let rig: HostRig
        var client: Client!

        init() throws {
            rig = try HostRig()
            try rig.host.start()
            try git("init", "-q")
            try write("a.txt", "one\ntwo\nthree\n")
            try write("sub/b.txt", "bee\n")
            try write(".gitignore", "build/\n")
            try git("add", "-A")
            try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first")
        }

        var folder: String { rig.folder.path }

        func write(_ name: String, _ text: String) throws {
            let url = rig.folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = rig.folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        func connect(control: GrantControl = .full) async throws {
            let store = GrantStore(rig.paths.grants)
            let grant = try store.allow("mac", control: control, socket: rig.paths.socket)
            client = try Client(rig.paths.socket)
            try await until { !self.client.got.isEmpty }
            client.hello(grant: grant)
            try await until { self.client.got.count >= 3 }
        }

        func send<T: Encodable>(_ value: T) { client.socket.send(StreamWire.encode(value)) }

        func answer<T: Decodable>(_ id: String, as: T.Type) async throws -> T {
            func find() -> T? {
                client.raws.first { StreamWire.type($0) == "result" && StreamWire.id($0) == id }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            }
            try await until { find() != nil }
            return find()!
        }

        func pushes() -> [GitChanged] {
            client.raws.filter { StreamWire.type($0) == GitChanged.type }.compactMap { try? JSONDecoder().decode(GitChanged.self, from: $0) }
        }

        func finish() { rig.finish() }
    }

    @Test func porcelainTwoReadsEveryKindOfLine() {
        let output = [
            "1 .M N... 100644 100644 100644 aaa aaa sub/a b.txt", "1 A. N... 000000 100644 100644 000 bbb new.txt",
            "2 R. N... 100644 100644 100644 ccc ccc R100 moved.txt", "old.txt", "u UU N... 1 2 3 4 h1 h2 h3 clash.txt",
            "1 .D N... 100644 100644 000000 ddd ddd gone.txt", "? untracked/", "! build/", "1 .M N... 1 1 1 a a other/x.txt",
        ].joined(separator: "\0") + "\0"
        let all = GitStatus.parseV2(output, prefix: "")
        #expect(all["sub/a b.txt"] == .modified)
        #expect(all["new.txt"] == .added)
        #expect(all["moved.txt"] == .renamed)
        #expect(all["old.txt"] == nil)
        #expect(all["clash.txt"] == .conflicted)
        #expect(all["gone.txt"] == .deleted)
        #expect(all["untracked/"] == .untracked)
        #expect(all["build/"] == .ignored)
        // Under a prefix: only its paths, relative to it.
        #expect(GitStatus.parseV2(output, prefix: "other/") == ["x.txt": .modified])
        // The explorer's lookups over a map: folders take their strongest file, whole folders cover what's in them.
        let status = GitStatus(states: all, root: "/r")
        #expect(status.state(of: "/r/sub") == .modified)
        #expect(status.state(of: "/r/untracked/deep/f") == .untracked)
        #expect(status.state(of: "/r/build/x") == .ignored)
        #expect(status.state(of: "/r/clean.txt") == nil)
    }

    @Test func statusComesWholeThenAsChangesAndIsPushedWhileWatched() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        try rig.write("a.txt", "one\nTWO\nthree\nfour\n")
        try rig.write("new.txt", "fresh\n")
        try rig.write("build/out.o", "x")
        try rig.write("staged.txt", "s\n")
        rig.send(GitStatusAsk(id: "s1", root: rig.folder, watch: true))
        let first = try await rig.answer("s1", as: GitStatusResult.self)
        #expect(first.ok)
        #expect(first.states?.full == true)
        #expect(first.states?.set == ["a.txt": .modified, "new.txt": .untracked, "staged.txt": .untracked, "build/": .ignored])
        let runs = rig.rig.host.git.runs

        // Asked again with nothing changed: no git run, nothing to send.
        rig.send(GitStatusAsk(id: "s2", root: rig.folder))
        let second = try await rig.answer("s2", as: GitStatusResult.self)
        #expect(second.states == GitStates())
        #expect(rig.rig.host.git.runs == runs)

        // A change the box hears of settles, then one status, and only what changed is pushed.
        try FileManager.default.removeItem(atPath: rig.folder + "/new.txt")
        try rig.write("sub/b.txt", "bee\nsee\n")
        rig.rig.host.git.touched(rig.folder + "/sub/b.txt")
        rig.rig.host.git.touched(rig.folder + "/new.txt")
        try await until { !rig.pushes().isEmpty }
        #expect(rig.pushes().first?.states == GitStates(set: ["sub/b.txt": .modified], gone: ["new.txt"]))
        #expect(rig.rig.host.git.runs == runs + 1)

        // Staging moves the index, which no file under the folder shows: the repository's own folder says so.
        try rig.git("add", "staged.txt")
        try await until { rig.pushes().count >= 2 }
        #expect(rig.pushes()[1].states == GitStates(set: ["staged.txt": .added]))

        // Unwatched: nothing more is pushed.
        rig.send(GitUnwatch(root: rig.folder))
        try await until { !rig.rig.host.git.watching(rig.folder) }
        let pushed = rig.pushes().count
        try rig.write("c.txt", "c\n")
        rig.rig.host.git.touched(rig.folder)
        try await Task.sleep(for: .milliseconds(700))
        #expect(rig.pushes().count == pushed)
    }

    @Test func aTurnsEndOrACommandInATerminalIsAChange() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        rig.rig.host.terminals.base = ["HOME": rig.rig.root.path, "PATH": "/usr/bin:/bin"]
        rig.send(GitStatusAsk(id: "s1", root: rig.folder, watch: true))
        _ = try await rig.answer("s1", as: GitStatusResult.self)
        rig.send(PtyOpen(id: "o", cwd: rig.folder, cols: 80, rows: 24, shell: "/bin/sh"))
        let pty = try await rig.answer("o", as: PtyResult.self).ptyId ?? ""
        rig.send(PtyInput(ptyId: pty, data: Data("echo more >> a.txt\r".utf8)))
        try await until { rig.pushes().contains { $0.states.set?["a.txt"] == .modified } }
        rig.rig.host.terminals.stopAll()
    }

    @Test func diffAndBaseAreTheBoxsOwnAndStayInServedFolders() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect()
        try rig.write("a.txt", "one\nTWO\nthree\n")
        rig.send(GitDiffAsk(id: "d1", root: rig.folder))
        let diff = try await rig.answer("d1", as: GitTextResult.self)
        #expect(diff.ok)
        let changes = UnifiedDiff.files(diff.diff ?? "", root: URL(fileURLWithPath: rig.folder))
        #expect(changes.map(\.path) == [rig.folder + "/a.txt"])
        #expect(changes.first?.added == 1 && changes.first?.removed == 1)
        rig.send(GitDiffAsk(id: "d2", root: rig.folder, path: rig.folder + "/sub/b.txt"))
        #expect(try await rig.answer("d2", as: GitTextResult.self).diff == "")
        rig.send(GitDiffAsk(id: "d3", root: rig.folder, staged: true))
        #expect(try await rig.answer("d3", as: GitTextResult.self).diff == "")

        rig.send(GitLineChangesAsk(id: "b1", path: rig.folder + "/a.txt"))
        #expect(try await rig.answer("b1", as: GitTextResult.self).base == "one\ntwo\nthree\n")
        try rig.write("fresh.txt", "x\n")
        rig.send(GitLineChangesAsk(id: "b2", path: rig.folder + "/fresh.txt"))
        let fresh = try await rig.answer("b2", as: GitTextResult.self)
        #expect(fresh.ok && fresh.base == nil)

        let outside = rig.rig.root.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("s\n".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/out", withDestinationPath: outside.path)
        rig.send(GitStatusAsk(id: "r1", root: outside.path))
        rig.send(GitDiffAsk(id: "r2", root: rig.folder + "/out"))
        rig.send(GitLineChangesAsk(id: "r3", path: rig.folder + "/out/s.txt"))
        rig.send(GitLineChangesAsk(id: "r4", path: rig.folder + "/../away/s.txt"))
        rig.send(GitDiffAsk(id: "r5", root: "relative"))
        #expect(try await rig.answer("r1", as: GitStatusResult.self).code == .deniedPath)
        #expect(try await rig.answer("r2", as: GitTextResult.self).code == .deniedPath)
        #expect(try await rig.answer("r3", as: GitTextResult.self).code == .deniedPath)
        #expect(try await rig.answer("r4", as: GitTextResult.self).code == .deniedPath)
        #expect(try await rig.answer("r5", as: GitTextResult.self).code == .invalid)
    }

    @Test func onlyAFullGrantGetsGit() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.connect(control: .act)
        rig.send(GitStatusAsk(id: "s", root: rig.folder))
        rig.send(GitDiffAsk(id: "d", root: rig.folder))
        #expect(try await rig.answer("s", as: GitStatusResult.self).code == .deniedControl)
        #expect(try await rig.answer("d", as: GitTextResult.self).code == .deniedControl)
    }
}
