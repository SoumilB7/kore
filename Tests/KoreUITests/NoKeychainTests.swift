import Foundation
import KoreCore
import LinkProtocol
@testable import src
import Testing

@testable import KoreUI

extension HostOverrideTests {
/// Kore never touches the Keychain (owner, 2026-11-21): a Claude login on this Mac is Claude's own,
/// never read, copied or deleted. Launch, a refresh, the popup, the same-account check, a switch,
/// Sign in on a box and Sign in here read none (the vault here counts every read); a source
/// guard keeps every Mac target free of Keychain calls.
@Suite("No Keychain in Kore", .serialized) @MainActor
struct NoKeychainTests {
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
    private func box(
        _ prints: [LoginPrint], signIn: (@MainActor (String, String?, @escaping @MainActor (URL) -> Void) async -> String?)? = nil
    ) -> LoginMoves.Box {
        LoginMoves.Box(
            key: "mybox", name: "mybox", unready: nil, device: nil, remote: { _, _, _, _ in fatalError("no copy here") },
            prints: { cli, _ in prints.filter { $0.cli == cli } }, login: { _, _ in nil }, signIn: signIn)
    }

    @Test func launchRefreshPopupSwitchAndTheCheckReadNoClaudeLogin() async throws {
        try await scratch { folder, vault in
            _ = CLIProfiles.note("claude", email: "me@example.com", workspace: "Example")
            let work = try CLIProfiles.prepare("claude")
            CLIProfiles.adopt("claude", work, email: "work@acme.dev")
            vault.set(Data("w".utf8), LoginVault.Place(cli: "claude", folder: CLIProfiles.folder("claude", work)))
            let store = AccountStore.shared
            await store.refresh("claude")
            await store.refresh("codex")
            LoginMoves.shared.boxes = { [self] in [box([LoginPrint(cli: "claude", login: "dev", email: "ME@example.com", fingerprint: "")])] }
            LoginMoves.shared.macs = { [] }
            LoginMoves.shared.settle()
            await LoginMoves.shared.check()?.value
            #expect(LoginMoves.shared.alsoOn("claude", nil) == nil && LoginMoves.shared.alsoOn("claude", work) == nil)
            store.switchLogin("claude", to: work, LoginPick.byMove())
            await store.refresh("claude")
            store.switchLogin("claude", to: nil, LoginPick.byMove())
            await store.refresh("claude")
            #expect(vault.reads() == 0)
            _ = folder
        }
    }

    @Test func onlyACopiedLoginIsFlaggedOnTwoDevicesNeverAClaudeOne() async throws {
        try await scratch { folder, vault in
            // An older Kore moved Claude's main there; Kore moved Codex's main there too.
            CLIProfiles.markMoved("claude", email: "me@example.com", box: "mybox")
            CLIProfiles.markMoved("codex", email: "me@example.com", box: "mybox")
            LoginMoves.shared.held = { _ in [.init(id: nil, email: "me@example.com", file: nil)] }
            LoginMoves.shared.macs = { [] }
            LoginMoves.shared.boxes = { [self] in [box([
                LoginPrint(cli: "claude", login: "main", email: "me@example.com", fingerprint: "f1"),
                LoginPrint(cli: "codex", login: "main", email: "me@example.com", fingerprint: "f2"),
            ])] }
            await LoginMoves.shared.check()?.value
            // Claude's are signed in, never copied: there's nothing to Keep.
            #expect(LoginMoves.shared.alsoOn("claude", nil) == nil && LoginMoves.shared.alsoOn("codex", nil) == "mybox")
            #expect(vault.reads() == 0)
            _ = folder
        }
    }

    @Test func signInOnABoxRunsClaudesOwnSignInThereAndLeavesThisLoginAlone() async throws {
        try await scratch { _, vault in
            _ = CLIProfiles.note("claude", email: "me@example.com", workspace: "Example")
            var opened: [URL] = []
            var asked: [String] = []
            var logins: [String?] = []
            let finish = AsyncStream<String?>.makeStream()
            let moves = LoginMoves.shared
            let beforeOpen = moves.openPage
            defer { moves.openPage = beforeOpen }
            moves.openPage = { opened.append($0) }
            moves.macs = { [] }
            moves.boxes = { [self] in [box([], signIn: { cli, login, open in
                asked.append(cli)
                logins.append(login)
                open(URL(string: "https://claude.ai/oauth/authorize?code=true")!)
                var said: String?? = nil
                for await one in finish.stream { said = .some(one); break }
                return said ?? nil
            })] }
            // Offered as a sign-in, never a copy, and only where Kore can start one.
            #expect(moves.targets("claude").map(\.name) == ["mybox"])
            moves.move("claude", nil, to: "mybox", fallback: nil)
            #expect(moves.line("claude", nil) == .signingIn("mybox"))
            // A second click while it runs starts nothing.
            moves.move("claude", nil, to: "mybox", fallback: nil)
            while asked.isEmpty || opened.isEmpty { await Task.yield() }
            #expect(asked == ["claude"] && opened.map(\.host) == ["claude.ai"])
            // Into the box's added account named for this login, never the box's own.
            #expect(logins == ["me"])
            finish.continuation.yield(nil)
            while moves.line("claude", nil) != nil { await Task.yield() }
            // This Mac's login stays here, unread and not marked moved.
            #expect(CLIProfiles.movedTo("claude", email: "me@example.com") == nil)
            #expect(vault.reads() == 0 && vault.held(LoginVault.Place(cli: "claude", folder: CLIProfiles.mainFolder("claude"))) != nil)
            // A sign-in that didn't finish says why, in the box's words.
            moves.move("claude", nil, to: "mybox", fallback: nil)
            while asked.count < 2 { await Task.yield() }
            finish.continuation.yield("Couldn't sign in on mybox")
            while moves.line("claude", nil) == .signingIn("mybox") { await Task.yield() }
            #expect(moves.line("claude", nil) == .failed("Couldn't sign in on mybox"))
        }
    }

    @Test func signInHereBringsAMovedClaudeLoginBackByClaudesOwnSignIn() async throws {
        try await scratch { _, vault in
            _ = CLIProfiles.note("claude", email: "me@example.com", workspace: "Example")
            CLIProfiles.markMoved("claude", email: "me@example.com", box: "mybox")
            let moves = LoginMoves.shared
            let before = moves.signInHere
            defer { moves.signInHere = before }
            var here: [String?] = []
            moves.signInHere = { cli, id in
                #expect(cli == "claude")
                here.append(id)
            }
            moves.boxes = { [self] in [box([], signIn: { _, _, _ in "no box sign-in for this" })] }
            moves.macs = { [] }
            moves.moveBack("claude", nil)
            // Listed here again, and Claude's own sign-in started for it: nothing read or copied.
            #expect(here == [nil] && CLIProfiles.movedTo("claude", email: "me@example.com") == nil)
            #expect(vault.reads() == 0 && moves.line("claude", nil) == nil)
        }
    }

    @Test func aMacLoginOfClaudeIsNeverReadWrittenOrDeleted() async throws {
        try await scratch { _, vault in
            let login = MacLogin(cli: "claude", id: nil)
            await #expect(throws: LoginMove.Failure.self) { _ = try await login.read() }
            await #expect(throws: LoginMove.Failure.self) { try await login.write(Data("x".utf8)) }
            await #expect(throws: LoginMove.Failure.self) { try await login.delete() }
            #expect(vault.reads() == 0 && vault.held(LoginVault.Place(cli: "claude", folder: CLIProfiles.mainFolder("claude"))) != nil)
        }
    }

    // MARK: The guard

    /// Every Mac target's sources make no Keychain call: no `SecItem*`, no `kSec*` item
    /// attribute, no `security` program run for an item, nothing linked for it. A word list of
    /// risky commands (`KoreAskList`) and the old helper's text Kore compares against are text,
    /// not calls. Code signing (`SecCode*`, `kSecGuestAttribute*`, `kSecCS*`) isn't the Keychain.
    @Test func noMacTargetCallsTheKeychain() throws {
        let root = Self.sources.standardizedFileURL.path
        let found = try Self.keychainCalls(root: root)
        #expect(found.isEmpty, "Keychain calls: \(found)")
        // The guard itself sees one.
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Kore"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        for (name, line) in [
            ("A", "let s = SecItemCopyMatching(q as CFDictionary, &out)"), ("B", "q[kSecClass as String] = kSecClassGenericPassword"),
            ("C", "process.executableURL = URL(fileURLWithPath: \"/usr/bin/security\")"), ("D", "run([\"security\", \"add-generic-password\", \"-s\", s])"),
            ("F", "shell([\"/bin/sh\", \"-c\", \"security unlock-keychain -p \\(p) login.keychain\"])"), ("G", "run(\"/bin/sh\", [\"-c\", \"list-keychains -d user\"])"),
            ("H", "let c = URLCredential(user: u, password: p, persistence: .permanent)"), ("I", "URLCredential(user: u, password: p, persistence: .synchronizable)"),
            ("J", "sh(\"security set-keychain-settings -t 3600\")"),
        ] {
            try line.write(to: fake.appendingPathComponent("Kore/\(name).swift"), atomically: true, encoding: .utf8)
        }
        try "let ok = kSecGuestAttributeAudit // code signing\nlet c = URLCredential(user: u, password: p, persistence: .forSession)"
            .write(to: fake.appendingPathComponent("Kore/E.swift"), atomically: true, encoding: .utf8)
        #expect(
            Set(try Self.keychainCalls(root: fake.path).map { String($0.prefix(6)) })
                == ["Kore/A", "Kore/B", "Kore/C", "Kore/D", "Kore/F", "Kore/G", "Kore/H", "Kore/I", "Kore/J"])
    }

    /// `path:line` of each Keychain call in the Mac targets' sources under `root` (kore-host,
    /// Linux only, and the storyline/test tools are left out; they never run in Kore.app).
    static func keychainCalls(root: String) throws -> [String] {
        let skipped = ["KoreHost/", "kore-host/", "KoreHostSys/", "korenet-e2e/"]
        // Text, not a call: the risky-command word lists, and the helper Kore set before 0.3.7.
        let allowed: [String: [String]] = [
            "AgentTools/KoreAskList.swift": ["find-generic-password", "\"security\""],
            "AgentTools/KoreAlwaysRule.swift": ["security find-generic-password"],
            "KoreCore/ClaudeSettings.swift": ["oldKeyHelper = \"security find-generic-password"],
        ]
        // Also: a `security` verb inside a shell string (`sh -c "security unlock-keychain"`), a
        // keychain verb alone, and a URL credential kept past the session (the Keychain holds it).
        let call = try NSRegularExpression(pattern: #"\bSecItem[A-Z]\w*|\bkSec(?!GuestAttribute|CS)\w+|\bSecKeychain\w*|\bSecAccess\w*|\bSecTrustedApplication\w*|/usr/bin/security\b|"security"|(?:add|find|delete)-(?:generic|internet)-password|dump-keychain"#
            + #"|\bsecurity\s+[a-z]+(?:-[a-z]+)+\b|\b(?:unlock|lock|create|delete|list|default|login|show)-keychains?\b|\bset-keychain-\w+"#
            + #"|\.permanent\b|\.synchronizable\b|\bURLCredentialStorage\b"#)
        var found: [String] = []
        let walker = try #require(FileManager.default.enumerator(atPath: root))
        for case let path as String in walker where path.hasSuffix(".swift") && !skipped.contains(where: path.hasPrefix) {
            let lines = try String(contentsOfFile: root + "/" + path, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard call.firstMatch(in: line, range: range) != nil else { continue }
                if allowed[path]?.contains(where: line.contains) == true { continue }
                found.append("\(path):\(n + 1)")
            }
        }
        return found.sorted()
    }
}
}
