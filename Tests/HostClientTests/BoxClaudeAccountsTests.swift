import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

@testable import src

/// The Mac's side of a box's Claude accounts, over a kore-host in this process: the list with
/// the shown chat's account, a switch of that chat, and one account's usage. The folders are the
/// test's, `claude` a fake: no login is read or made.
@MainActor
@Suite(.serialized)
struct BoxClaudeAccountsTests {
    func rig() throws -> BoxRig {
        let rig = try BoxRig()
        let accounts = rig.root.appendingPathComponent(".config/claude-accounts")
        for name in ["ajinkya", "work"] {
            try FileManager.default.createDirectory(at: accounts.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        rig.host.sessionEnv = ["HOME": rig.root.path]
        rig.host.accounts.status = { folder in
            switch folder?.lastPathComponent {
            case nil: ["loggedIn": true, "email": "me@example.com"]
            case "ajinkya": ["loggedIn": true, "email": "ajinkya@onfinance.in", "subscriptionType": "max"]
            default: ["loggedIn": false]
            }
        }
        rig.host.accounts.usage = { folder in
            PlanReading(account: .init(plan: "Claude Max", email: folder?.lastPathComponent == "ajinkya" ? "ajinkya@onfinance.in" : "me@example.com", access: .plan), limits: nil)
        }
        return rig
    }

    @Test func theMacListsSwitchesAndReadsTheBoxsAccounts() async throws {
        let rig = try rig()
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let accounts = connection.accounts
        accounts.viewing = (hc.id, rig.folder.path)

        #expect(await accounts.listClaude())
        #expect(accounts.claude.map(\.id) == ["main", "ajinkya", "work"])
        #expect(accounts.claude.map(\.signedIn) == [true, true, false])
        #expect(accounts.viewedLogin == "main")

        // The shown chat moves: the box keeps it, and its folder's new chats follow.
        #expect(await accounts.switchClaude(to: "ajinkya") == nil)
        #expect(accounts.viewedLogin == "ajinkya" && hc.record.account == "ajinkya")
        #expect(rig.host.accounts.folderDefault(rig.folder.path) == "ajinkya")
        // A gone account: the box's reason, nothing changed.
        #expect(await accounts.switchClaude(to: "nobody") != nil)
        #expect(hc.record.account == "ajinkya")

        // One account's usage, read on the box.
        #expect(try await accounts.claudeUsage("ajinkya").account.email == "ajinkya@onfinance.in")
        // The chat's own status: its account's.
        let said = await connection.command { HostWire.refresh(id: $0, provider: "claude", chatId: hc.id) }
        #expect(said.account?.email == "ajinkya@onfinance.in")
    }
}
