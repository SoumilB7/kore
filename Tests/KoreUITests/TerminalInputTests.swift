import AppKit
import Foundation
import HostClient
import SwiftTerm
import Testing

@testable import KoreUI

/// Text into a terminal (0.3.10): a box's prepared command waits for its shell's line editor
/// (typed while the shell started, the tty echoed it raw above the prompt); a paste waits the
/// same way; no program reads the clipboard back as input (OSC 52), on a box or here.
@MainActor @Suite("Terminal input")
struct TerminalInputTests {
    private func box(draft: String? = nil) -> BoxTerminalShell {
        let alias = "terminal-input-\(UUID().uuidString.prefix(6))"
        let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: FileManager.default.temporaryDirectory.appendingPathComponent(alias))) {
            ClosedTransport("no")
        }
        return BoxTerminalShell(connection: connection, cwd: "/home/me", draft: draft, history: nil)
    }

    @Test func aBoxsPreparedCommandWaitsForItsLineEditor() async throws {
        let shell = box(draft: "echo kore-dummy")
        var typed = Data()
        shell.typed = { typed.append($0) }
        // The shell's startup says things before its prompt: nothing is typed yet.
        shell.received(Data("Last login: today\r\n".utf8))
        try await Task.sleep(for: .milliseconds(120))
        #expect(typed.isEmpty)
        // Its editor is up (bracketed paste on): the command goes in once, as a paste, unrun.
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        for _ in 0..<100 where typed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let text = String(decoding: typed, as: UTF8.self)
        #expect(text == "\u{1B}[200~echo kore-dummy\u{1B}[201~")
        shell.received(Data("x".utf8))
        #expect(String(decoding: typed, as: UTF8.self) == text)
    }

    @Test func aShellThatNeverSaysTakesItOnceQuiet() async throws {
        let shell = box(draft: "echo kore-dummy")
        var typed = Data()
        shell.typed = { typed.append($0) }
        shell.received(Data("$ ".utf8))
        #expect(typed.isEmpty)
        for _ in 0..<60 where typed.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        // No bracketed paste asked for: plain text, no Return.
        #expect(String(decoding: typed, as: UTF8.self) == "echo kore-dummy")
    }

    /// Once the shell's editor has been up, a paste for a running program (`read`, `cat`) goes now.
    @Test func aPasteForARunningCommandGoesNow() async throws {
        let shell = box()
        var typed = Data()
        shell.typed = { typed.append($0) }
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        shell.received(Data("\u{1B}[?2004l\r\n".utf8))
        shell.view.typeAhead?.paste("kore-now")
        for _ in 0..<100 where typed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(String(decoding: typed, as: UTF8.self).contains("kore-now"))
    }

    /// Keys typed while the shell starts wait for its editor (it would drop them); the terminal's
    /// own replies to the shell never wait.
    @Test func keysTypedWhileStartingWaitForTheEditor() {
        let shell = box()
        var typed = Data()
        shell.typed = { typed.append($0) }
        shell.send(source: shell.view, data: Array("echo".utf8)[...])
        shell.send(source: shell.view, data: Array("\u{1B}[1;1R".utf8)[...])
        #expect(String(decoding: typed, as: UTF8.self) == "\u{1B}[1;1R")
        shell.received(Data("\u{1B}[?2004hready> ".utf8))
        #expect(String(decoding: typed, as: UTF8.self) == "\u{1B}[1;1Recho")
        shell.send(source: shell.view, data: Array("x".utf8)[...])
        #expect(String(decoding: typed, as: UTF8.self).hasSuffix("echox"))
    }

    /// A program asking for the clipboard (OSC 52 query) gets nothing back, on a box or here.
    @Test func noProgramReadsTheClipboard() async throws {
        let shell = box()
        var typed = Data()
        shell.typed = { typed.append($0) }
        #expect(shell.clipboardRead(source: shell.view) == nil)
        shell.view.feed(text: "\u{1B}]52;c;?\u{07}")
        try await Task.sleep(for: .milliseconds(100))
        #expect(typed.isEmpty)
        let local = KoreLocalTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        local.guardClipboard()
        #expect(local.terminalDelegate?.clipboardRead(source: local) == nil)
        #expect(local.terminalDelegate?.kittyClipboardCapabilities(source: local) == [])
    }

    @Test func aTypeAheadDeliversInOrderOnceReady() {
        var ready = false
        var out: [String] = []
        let ahead = TerminalTypeAhead(ready: { ready }, deliver: { out.append($0) })
        ahead.paste("one")
        ahead.paste("two")
        #expect(out.isEmpty)
        ready = true
        ahead.flush()
        ahead.paste("three")
        #expect(out == ["one", "two", "three"])
        ahead.paste("")
        #expect(out.count == 3)
    }
}
