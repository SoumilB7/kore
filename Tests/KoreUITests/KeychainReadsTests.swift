import Foundation
import KoreCore
import LinkProtocol
@testable import src
import Testing

@testable import KoreUI

/// Kore reads a Claude login's Keychain item only for a move the owner clicks at this Mac (macOS
/// asks then). Launch, an account refresh, the popup opening, the same-account check, a usage
/// read and a login switch read none: the vault here counts every read.
@Suite("Keychain reads only for a move", .serialized) @MainActor
struct KeychainReadsTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// A scratch home for the logins, a counting vault, and fake CLI status calls; all undone after.
    private func scratch(_ body: (URL, MemoryLoginVault) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keychain-reads-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let beforeRoot = CLIProfiles.root.value, beforeMains = CLIProfiles.mains.value
        let beforeCalls = StorylineSeams.accounts, beforeVault = LoginVault.store.value
        let moves = LoginMoves.shared
        let (beforeBoxes, beforeMacs, beforeHeld) = (moves.boxes, moves.macs, moves.held)
        let vault = MemoryLoginVault()
        LoginVault.store.value = vault
        CLIProfiles.root.value = folder.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": folder.appendingPathComponent("main-claude"), "codex": folder.appendingPathComponent("main-codex")]
        CLIProfiles.reload()
        AccountStore.shared.reset()
        moves.reset()
        defer {
            moves.reset()
            (moves.boxes, moves.macs, moves.held) = (beforeBoxes, beforeMacs, beforeHeld)
            AccountStore.shared.reset()
            StorylineSeams.accounts = beforeCalls
            LoginVault.store.value = beforeVault
            CLIProfiles.root.value = beforeRoot
            CLIProfiles.mains.value = beforeMains
            CLIProfiles.reload()
            try? FileManager.default.removeItem(at: folder)
        }
        var claude = try #require(Registry.provider("claude")?.account.calls)
        claude.status = { ["loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "orgName": "Example", "subscriptionType": "max"] }
        var codex = try #require(Registry.provider("codex")?.account.calls)
        codex.status = { ["account": ["type": "chatgpt", "email": "me@example.com", "planType": "pro"], "requiresOpenaiAuth": true] }
        let calls = ["claude": claude, "codex": codex]
        StorylineSeams.accounts = { calls[$0] }
        // Each Claude login held where the real one would be, so a read would count.
        let login = Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r-1","expiresAt":1}}"#.utf8)
        vault.set(login, LoginVault.Place(cli: "claude", folder: CLIProfiles.mainFolder("claude")))
        try await body(folder, vault)
    }

    /// A box answering with these logins (who they are; no fingerprint).
    private func box(_ prints: [LoginPrint]) -> LoginMoves.Box {
        LoginMoves.Box(
            key: "mybox", name: "mybox", unready: nil, device: nil, remote: { _, _, _, _ in fatalError("no move here") },
            prints: { cli, _ in prints.filter { $0.cli == cli } }, login: { _, _ in nil })
    }

    @Test func launchRefreshPopupSwitchAndTheCheckReadNoKeychainItem() async throws {
        try await scratch { folder, vault in
            _ = CLIProfiles.note("claude", email: "me@example.com", workspace: "Example")
            let work = try CLIProfiles.prepare("claude")
            CLIProfiles.adopt("claude", work, email: "work@acme.dev")
            vault.set(Data("w".utf8), LoginVault.Place(cli: "claude", folder: CLIProfiles.folder("claude", work)))
            let store = AccountStore.shared
            // An account refresh, both CLIs.
            await store.refresh("claude")
            await store.refresh("codex")
            // Launch and the popup opening: what's owed is sent, the same account looked for.
            LoginMoves.shared.boxes = { [self] in [box([LoginPrint(cli: "claude", login: "dev", email: "ME@example.com", fingerprint: "")])] }
            LoginMoves.shared.macs = { [] }
            LoginMoves.shared.settle()
            await LoginMoves.shared.check()?.value
            #expect(LoginMoves.shared.alsoOn("claude", nil) == "mybox" && LoginMoves.shared.alsoOn("claude", work) == nil)
            // A login switch, and back.
            store.switchLogin("claude", to: work, LoginPick.byMove())
            await store.refresh("claude")
            store.switchLogin("claude", to: nil, LoginPick.byMove())
            await store.refresh("claude")
            #expect(vault.reads() == 0)
            _ = folder
        }
    }

    @Test func theSameEmailOrAccountIdOnBothIsFlaggedAnotherIsNot() async throws {
        try await scratch { folder, vault in
            let file = folder.appendingPathComponent("work.claude.json")
            try Data(#"{"oauthAccount":{"emailAddress":"work@acme.dev","accountUuid":"uuid-w"}}"#.utf8).write(to: file)
            LoginMoves.shared.held = { cli in
                cli == "claude"
                    ? [.init(id: nil, email: "me@example.com", file: nil), .init(id: "work", email: nil, file: file), .init(id: "solo", email: "solo@example.com", file: nil)]
                    : [.init(id: nil, email: "me@example.com", file: nil)]
            }
            LoginMoves.shared.macs = { [] }
            LoginMoves.shared.boxes = { [self] in [box([
                // An older box: its email only.
                LoginPrint(cli: "claude", login: "main", email: " Me@Example.com", fingerprint: "f1"),
                // Its id, no email.
                LoginPrint(cli: "claude", login: "dev", email: nil, fingerprint: "", account: "uuid-w"),
                // Another account.
                LoginPrint(cli: "claude", login: "x", email: "someone@else.dev", fingerprint: "", account: "uuid-x"),
                LoginPrint(cli: "codex", login: "main", email: "other@example.com", fingerprint: "", account: "team"),
            ])] }
            await LoginMoves.shared.check()?.value
            let moves = LoginMoves.shared
            #expect(moves.alsoOn("claude", nil) == "mybox" && moves.alsoOn("claude", "work") == "mybox")
            #expect(moves.alsoOn("claude", "solo") == nil && moves.alsoOn("codex", nil) == nil)
            #expect(vault.reads() == 0)
        }
    }

    @Test func aMoveReadsTheKeychainItemOnlyFromItsClick() throws {
        // Source guard: the only vault reads in the app are a move's (`MacLogin.read`, which may
        // ask) and another Mac's move's own staged item or a Codex file (`MacLoginMoves`).
        let root = Self.sources.standardizedFileURL.path
        var reading: Set<String> = []
        let walker = try #require(FileManager.default.enumerator(atPath: root))
        for case let path as String in walker where path.hasSuffix(".swift") && !path.contains("Storylines") && path != "KoreCore/LoginVault.swift" {
            let source = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
            let marks = ["prompt: true)", "prompt: false)", "ClaudeKeychain.", "vault().read(", "vault.read(", "store.value.read("]
            if marks.contains(where: source.contains) { reading.insert(path) }
        }
        #expect(reading == ["KoreUI/Account/LoginMoves.swift", "KoreLink/Host/MacLoginMoves.swift"])
        let moves = try String(contentsOfFile: root + "/KoreUI/Account/LoginMoves.swift", encoding: .utf8)
        #expect(moves.components(separatedBy: "prompt: ").count == 2 && moves.contains("read(place, prompt: true)"))
        // Another Mac's ask for a Claude login is refused before anything is read.
        let mac = try String(contentsOfFile: root + "/KoreLink/Host/MacLoginMoves.swift", encoding: .utf8)
        let refuse = try #require(mac.range(of: "if cli == \"claude\" { return .refused(id, .invalid, \"Move it from"))
        let read = try #require(mac.range(of: "func exportRead("))
        #expect(refuse.lowerBound < read.lowerBound)
    }
}
