import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Testing

@testable import KoreUI
@testable import src

/// Two windows on one box (different folders), the Welcome that opened the first, a paired Mac
/// folder's cue and its History, all at once: one `attach`, and the box never turns this Mac away
/// as another Kore holding it.
@Suite("one link per box", .serialized) @MainActor
struct OneBoxLinkUITests {
    final class Dials { var scripts: [PairedBoxTests.Script] = [] }

    func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func window(_ alias: String, _ folder: String) -> (BoxBinding, Workspace) {
        let box = BoxBinding(alias: alias, folder: folder)
        let workspace = Workspace(folder: box.folderURL, restore: false, box: box)
        box.workspace = workspace
        return (box, workspace)
    }

    @Test func windowsHistoryAndTheCueShareOneLink() async throws {
        let dials = Dials()
        let alias = "onelink-\(UUID().uuidString.prefix(6))"
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kore-onelink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        HostConnection.adopt(
            HostConnection(alias: alias, cache: HostCache(alias: alias, root: cacheRoot)) {
                let toHost = Pipe(), toMac = Pipe()
                dials.scripts.append(PairedBoxTests.Script(PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting)))
                return PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
            })
        let base = PairedBoxTests()
        let other = "/home/me/other"
        func link(_ script: PairedBoxTests.Script) async throws {
            script.send(.challenge(nonce: "bm9uY2U="))
            _ = try #require(await script.next("hello"))
            script.send(json: [
                "t": "welcome", "proto": ["major": 1, "minor": 10], "epoch": "e1", "host": ["name": alias, "koreVersion": "1", "kind": "box"],
                "providers": [], "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream", "history"],
            ])
            script.send(.snapshot(rev: 1, windows: [base.window(["c1"])], chats: [base.meta("c1", "Main-struc")]))
        }

        // The Welcome shows the box; a folder opens from it, and the Welcome lets go before the
        // folder's window takes the link.
        let welcome = BoxBinding.connection(alias)
        welcome.retain()
        #expect(await until { dials.scripts.count == 1 })
        try await link(try #require(dials.scripts.first))
        #expect(await until { welcome.isOnline })
        let (first, _) = window(alias, PairedBoxTests.boxFolder)
        welcome.release()
        first.windowOpened()
        defer { first.windowClosed() }
        #expect(await until { dials.scripts.count == 2 })
        let box = try #require(dials.scripts.last)
        try await link(box)
        #expect(await until { first.connection.isOnline })

        // A second folder's window on the same box.
        let (second, _) = window(alias, other)
        second.windowOpened()
        defer { second.windowClosed() }

        // A paired Mac folder: its cue and its History, on the same link.
        PairedBox.pairFor = { _ in SyncPair(mac: "/tmp/kore-onelink-mac", alias: alias, box: PairedBoxTests.boxFolder) }
        defer { PairedBox.pairFor = { SyncPairs.pair(mac: $0.standardizedFileURL.path) } }
        let folderWindow = Workspace(folder: URL(fileURLWithPath: "/tmp/kore-onelink-mac"), restore: false)
        let paired = try #require(folderWindow.paired)
        folderWindow.historyOpened()
        defer { folderWindow.historyClosed() }
        let ask = try #require(await box.next("history.list"))
        box.send(.historyPage(id: try #require(ask["id"] as? String), windowId: BoxFolder.windowId(PairedBoxTests.boxFolder), sessions: [], more: false))
        #expect(await until { paired.line == "\(alias) · 1 chat here" })

        // One connection for all of them, no dial since the window's, and the box never said another Kore holds it.
        #expect(first.connection === second.connection && second.connection === BoxBinding.connection(alias))
        #expect(HostConnection.existing(alias) === first.connection)
        try await Task.sleep(for: .milliseconds(100))
        #expect(dials.scripts.count == 2)
        #expect(first.connection.phase == .online)
    }
}
