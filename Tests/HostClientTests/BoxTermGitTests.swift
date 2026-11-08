import Foundation
import KoreCore
import Testing

@testable import HostClient
@testable import KoreHost
@testable import LinkProtocol

/// A box window's terminal and git through a kore-host in this process, over the link as the
/// window uses it: `BoxPty` and `BoxGitStatus`.
@Suite("box terminals and git", .serialized)
@MainActor
struct BoxTermGitTests {
    /// The rig's connection, its transports kept so a test can drop the link.
    @MainActor private final class Link {
        let connection: HostConnection

        init(_ rig: BoxRig) {
            let (path, grant) = (rig.host.paths.socket.path, rig.grant)
            let made = Made()
            connection = HostConnection(alias: "local", cache: HostCache(alias: "local", root: rig.root.appendingPathComponent("cache"))) {
                let transport = DaemonTransport(path: path, grant: grant)
                made.all.append(transport)
                return transport
            }
            self.made = made
            connection.backoff = [.milliseconds(50)]
            connection.retain()
        }

        @MainActor final class Made { var all: [DaemonTransport] = [] }
        private let made: Made
        var transports: [DaemonTransport] { made.all }
    }

    private func git(_ folder: URL, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func aBoxShellTypesResizesSurvivesADropAndEnds() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        rig.host.terminals.base = ["HOME": rig.root.path, "PATH": "/usr/bin:/bin", "PS1": "$ "]
        let link = Link(rig)
        #expect(await until(5) { link.connection.isOnline })
        #expect(link.connection.caps.contains("pty"))

        let pty = BoxPty(connection: link.connection, cwd: rig.folder.path)
        var screen = Data()
        var resets = 0
        var ended: Int32?
        var shell: String?
        pty.output = { bytes, reset in
            if reset { resets += 1 }
            screen.append(bytes)
        }
        pty.exited = { ended = $0 }
        pty.opened = { shell = $0 }
        var text: String { String(decoding: screen, as: UTF8.self) }
        pty.resize(cols: 100, rows: 30)
        // Typed before the shell is there: it goes once it is.
        pty.input(Data("echo h''i\r".utf8))
        pty.open()
        #expect(await until(5) { text.contains("hi\r\n") })
        #expect(shell != nil)
        pty.input(Data("stty size\r".utf8))
        #expect(await until(5) { text.contains("30 100") })
        pty.resize(cols: 90, rows: 20)
        pty.input(Data("stty size\r".utf8))
        #expect(await until(5) { text.contains("20 90") })

        // The link drops; the shell writes meanwhile; back, it shows that once, with no reset.
        pty.input(Data("sleep 0.3; echo la''ter\r".utf8))
        #expect(await until(5) { text.contains("sleep 0.3") })
        link.transports.last?.close()
        #expect(await until(5) { !link.connection.isOnline })
        #expect(await until(5) { link.connection.isOnline })
        #expect(await until(5) { text.contains("later\r\n") })
        try await Task.sleep(for: .milliseconds(200))
        #expect(text.components(separatedBy: "later\r\n").count == 2)
        #expect(resets == 0)
        #expect(pty.stood == Int64(screen.count))

        pty.input(Data("exit 7\r".utf8))
        #expect(await until(5) { ended == 7 })
        #expect(await until(5) { rig.host.terminals.count == 0 })
        link.connection.release()
    }

    @Test func closingTheTabHangsUpTheShell() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        rig.host.terminals.base = ["HOME": rig.root.path, "PATH": "/usr/bin:/bin"]
        let link = Link(rig)
        let pty = BoxPty(connection: link.connection, cwd: rig.folder.path)
        pty.open()
        #expect(await until(5) { rig.host.terminals.count == 1 && pty.ptyId != nil })
        pty.close()
        #expect(await until(5) { rig.host.terminals.count == 0 })
        link.connection.release()
    }

    @Test func gitColoursComeFollowChangesAndStopWhenHidden() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let folder = rig.folder
        try git(folder, "init", "-q")
        try Data("one\ntwo\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try git(folder, "add", "-A")
        try git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first")
        try Data("one\nTWO\nthree\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("new"), withIntermediateDirectories: true)
        try Data("n\n".utf8).write(to: folder.appendingPathComponent("new/n.txt"))

        let link = Link(rig)
        #expect(await until(5) { link.connection.isOnline })
        let status = BoxGitStatus(root: folder.path, connection: link.connection)
        var moved: [[String]?] = []
        status.moved = { moved.append($0) }
        status.visible = true
        #expect(await until(5) { status.state(of: folder.path + "/a.txt") == .modified })
        #expect(status.state(of: folder.path + "/new/n.txt") == .untracked)
        #expect(status.state(of: folder.path + "/new") == .untracked)
        let runs = rig.host.git.runs

        // A change the box hears of comes as what changed; the rest of the map stays as it was.
        let before = status.status
        try Data("one\ntwo\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        rig.host.git.touched(folder.path + "/a.txt")
        #expect(await until(5) { status.state(of: folder.path + "/a.txt") == nil })
        #expect(status.status != before)
        #expect(status.state(of: folder.path + "/new/n.txt") == .untracked)
        #expect(moved.last == [folder.path + "/a.txt"])
        #expect(rig.host.git.runs == runs + 1)

        // The editor's bars: HEAD's text from the box, the diff here.
        try Data("one\nTWO\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let bars = await status.lineChanges(of: folder.path + "/a.txt", text: "one\nTWO\n")
        #expect(bars.marks == [1: .modified])
        // Kept: asked again, the box isn't.
        #expect(await status.base(of: folder.path + "/a.txt") == "one\ntwo\n")
        guard case .success(let changes) = await status.diff() else { Issue.record("no diff"); return }
        #expect(changes.map(\.path) == [folder.path + "/a.txt"])

        // Hidden: the box stops watching.
        status.visible = false
        #expect(await until(5) { !rig.host.git.watching(folder.path) })
        link.connection.release()
    }

    @Test func aChangeKeepsItsCountsUnderTheWindowsName() {
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
        let change = UnifiedDiff.files(diff, root: URL(fileURLWithPath: "/home/me/app"))[0]
        let named = change.at { "/mybox/home/app" + $0.dropFirst("/home/me/app".count) }
        #expect(named.path == "/mybox/home/app/a.txt")
        #expect(named.added == 1 && named.removed == 1 && named.hunks == change.hunks)
    }
}
