import Foundation
import KoreCore
import Testing

@testable import HostClient
@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// How a box window's parts meet: a box file attached by its path, a file written over the link
/// moving git, a shell's foreground job, and a goodbye ending the shells.
@Suite("box glue", .serialized)
@MainActor
struct BoxGlueTests {
    @Test func aBoxFileGoesByItsPathAndOnlyFromAServedFolder() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        let (chat, _) = rig.chat(connection, id: nil)
        await chat.startOnce()
        let inside = rig.folder.path + "/notes.txt"
        try Data("on the box\n".utf8).write(to: URL(fileURLWithPath: inside))
        #expect(BoxFileRef.path(BoxFileRef.url(inside)) == inside)
        #expect(BoxFileRef.path(URL(fileURLWithPath: inside)) == nil)

        #expect(chat.sendFromLink("read it", files: [BoxFileRef.url(inside)]))
        #expect(await until(5) { !(rig.made.last?.files ?? []).isEmpty })
        // Not uploaded: the box's CLI gets the file where it is.
        #expect((rig.made.last?.files ?? []).first?.url.path == inside)
        #expect((rig.made.last?.files ?? []).first?.name == "notes.txt")
        #expect(await until(5) { !chat.isBusy })

        let outside = rig.root.path + "/secret.txt"
        try Data("no\n".utf8).write(to: URL(fileURLWithPath: outside))
        let count = (rig.made.last?.files ?? []).count
        #expect(chat.sendFromLink("and this", files: [BoxFileRef.url(outside)]))
        try await Task.sleep(for: .milliseconds(300))
        #expect((rig.made.last?.files ?? []).count == count)
        chat.close()
        connection.release()
    }

    @Test func aWriteOverTheLinkMovesGitAndAShellSaysItsJob() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let folder = rig.folder
        for args in [["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = args
            git.currentDirectoryURL = folder
            try git.run()
            git.waitUntilExit()
        }
        rig.host.terminals.base = ["HOME": rig.root.path, "PATH": "/usr/bin:/bin"]
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })

        // The explorer shows; a file saved over the link comes back as its state, unasked.
        let git = BoxGitStatus(root: folder.path, connection: connection)
        git.visible = true
        try await Task.sleep(for: .milliseconds(200))
        let (result, _) = await connection.commandRaw {
            HostWire.command(id: $0, .control(.fsWrite, ControlArgs(text: "hi\n", path: folder.path + "/new.txt")))
        }
        #expect(result.ok)
        #expect(await until(5) { git.state(of: folder.path + "/new.txt") == .untracked })

        // A shell's foreground job: said when it starts and when it ends.
        let pty = BoxPty(connection: connection, cwd: folder.path)
        var text = ""
        pty.output = { bytes, _ in text += String(decoding: bytes, as: UTF8.self) }
        pty.open()
        #expect(await until(5) { pty.ptyId != nil })
        #expect(!pty.busy)
        pty.input(Data("sleep 1\r".utf8))
        #expect(await until(5) { pty.busy })
        #expect(await until(5) { !pty.busy })

        // A goodbye (Kore quitting, the last window closing) ends the box's shells.
        let other = BoxPty(connection: connection, cwd: folder.path)
        other.open()
        #expect(await until(5) { other.ptyId != nil && rig.host.terminals.count == 2 })
        HostConnection.adopt(connection)
        HostConnection.quitAll()
        #expect(await until(5) { rig.host.terminals.count == 0 })
        git.visible = false
        connection.release()
    }
}
