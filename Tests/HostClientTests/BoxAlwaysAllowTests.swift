import AgentTools
import Foundation
import HostClient
import KoreHost
import LinkProtocol
import Testing

@testable import KoreCore
@testable import src

/// Always allow in a box chat driven by a Mac with full control: the card keeps its button, the
/// answer reaches the box's chat as `.allowAlways`, and the box's CLI keeps the rule there.
@Suite("box always allow", .serialized)
@MainActor
struct BoxAlwaysAllowTests {
    /// A Mac chat on the rig's box with one message sent, so the box has its chat and CLI.
    func started(_ rig: BoxRig, provider: ProviderDescriptor = .claude) async throws -> (Chat, HostConnection, HostChat) {
        let connection = rig.connection()
        connection.retain()
        #expect(await until { connection.isOnline })
        let (chat, backend) = rig.chat(connection, id: nil, provider: provider)
        await chat.startOnce()
        #expect(chat.sendFromLink("one"))
        #expect(await until { !rig.made.isEmpty && !chat.isBusy })
        let link = try #require(backend())
        let hc = try #require(link.chatId.flatMap(rig.host.chat))
        return (chat, connection, hc)
    }

    @Test func aClaudeAlwaysLandsInTheBoxProjectsSettingsAndTheHookStandsAside() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (chat, connection, hc) = try await started(rig)
        defer { connection.release() }
        #expect(connection.caps.contains(LinkPolicy.alwaysAllowCap))

        // The CLI's ask, as the box's chat shows it.
        let command = "sudo apt install jq"
        let request = PermissionRequest(
            id: "r1",
            [
                "tool_name": "Bash", "input": ["command": .string(command)],
                "permission_suggestions": [
                    ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "sudo apt install *"]], "behavior": "allow", "destination": "localSettings"]
                ],
            ])
        var card = Approval(id: "ap1", title: "Run apt", detail: nil, body: command, canAlwaysAllow: true, questions: [])
        card.alwaysRule = "sudo apt install *"
        // The box's CLI keeps what an answer tells it, in its folder (the box chat's), as claude does.
        let box = try #require(hc.chat).folder
        rig.cli.answered = { _, decision in
            let told = ClaudeBackend.decision(decision, for: request, in: box).payload(for: request)
            for update in told["updatedPermissions"]?.array ?? [] where update["type"]?.string == "addRules" && update["destination"]?.string == "localSettings" {
                let rules = (update["rules"]?.array ?? []).compactMap { r in r["ruleContent"]?.string.map { "\(r["toolName"]?.string ?? "")(\($0))" } }
                Self.keep(rules, in: box)
            }
        }
        rig.cli.sink.yield(.approvalRequested(card))

        // This Mac's card is a Mac chat's: the button, its rule, its tooltip.
        #expect(await until { chat.approvals.pending.first?.id == "ap1" })
        let shown = try #require(chat.approvals.pending.first)
        #expect(shown.canAlwaysAllow && shown.alwaysAllowNote == nil && shown.alwaysHelp == "Always allow `sudo apt install …`")

        // The box's hook asks before, and stands aside after.
        let input: [String: Any] = ["permission_mode": "auto", "tool_name": "Bash", "tool_input": ["command": "sudo apt install curl"], "cwd": box.path]
        let env = ["HOME": rig.root.path]
        #expect(KoreAskList.answer(input, rules: { KoreAskList.settingsRules(input, environment: env) }) != nil)
        chat.answer(shown, .allowAlways)
        #expect(await until { rig.cli.answers == ["ap1 allowAlways"] })
        let file = box.appendingPathComponent(".claude/settings.local.json")
        #expect(box.standardizedFileURL.path == rig.folder.standardizedFileURL.path)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Bash(sudo apt install *)"))
        #expect(KoreAskList.answer(input, rules: { KoreAskList.settingsRules(input, environment: env) }) == nil)
        #expect(chat.approvals.pending.isEmpty && !chat.transcriptView.entries.contains { $0.text.hasPrefix("Couldn't answer") })
        chat.close()
    }

    @Test func aCodexAlwaysGoesAsCodexsOwn() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (chat, connection, _) = try await started(rig, provider: .codex)
        defer { connection.release() }
        let params: JSONValue = [
            "threadId": "th", "itemId": "i1", "command": "sudo apt install jq", "cwd": .string(rig.folder.path),
            "proposedExecpolicyAmendment": ["sudo", "apt", "install"],
        ]
        let request = try #require(CodexApproval(id: 7, method: "item/commandExecution/requestApproval", params: params))
        var told: JSONValue?
        rig.cli.answered = { _, decision in told = CodexBackend.decision(decision, for: request).result(for: request) }
        var card = Approval(id: "ap2", title: "Run apt", detail: nil, body: "sudo apt install jq", canAlwaysAllow: true, questions: [])
        card.alwaysRule = "sudo apt install *"
        rig.cli.sink.yield(.approvalRequested(card))
        #expect(await until { chat.approvals.pending.first?.id == "ap2" })
        let shown = try #require(chat.approvals.pending.first)
        #expect(shown.canAlwaysAllow)
        chat.answer(shown, .allowAlways)
        #expect(await until { rig.cli.answers == ["ap2 allowAlways"] })
        #expect(told?["decision"]?["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"] == ["sudo", "apt", "install"])
        chat.close()
    }

    @Test func aCriticalRemovalIsRefusedOnTheBox() async throws {
        let rig = try BoxRig()
        defer { rig.finish() }
        let (chat, connection, _) = try await started(rig)
        defer { connection.release() }
        var card = Approval(id: "ap3", title: "Run rm", detail: nil, body: "rm -rf .", canAlwaysAllow: true, questions: [])
        card.command = "rm -rf ."
        card.cwd = rig.folder.path
        rig.cli.sink.yield(.approvalRequested(card))
        #expect(await until { chat.approvals.pending.first?.id == "ap3" })
        chat.answer(try #require(chat.approvals.pending.first), .allowAlways)
        // Refused: the card comes back with the box's words, and the CLI heard nothing.
        #expect(await until { chat.transcriptView.entries.contains { $0.text.contains(LinkPolicy.boxCriticalAlwaysLine) } })
        #expect(await until { chat.approvals.pending.first?.id == "ap3" })
        #expect(rig.cli.answers.isEmpty)
        chat.close()
    }

    @Test func anOldBoxOrAnActGrantKeepsItOff() async throws {
        // An act grant: no full control, so no Always allow here.
        let rig = try BoxRig(control: .act)
        defer { rig.finish() }
        let connection = rig.connection()
        connection.retain()
        defer { connection.release() }
        #expect(await until { connection.isOnline })
        let act = LinkChatBackend(connection: connection, provider: .claude, folder: rig.folder.path, chatId: nil)
        #expect(act.alwaysRefused == LinkPolicy.boxAlwaysAllowFull)

        // A full grant on a kore-host from before `alwaysAllow`: stripped, and says why.
        let (client, host) = FakeHost.pair()
        let old = HostConnection(alias: "old", cache: HostCache(alias: "old", root: rig.root.appendingPathComponent("old"))) { client }
        old.retain()
        defer { old.release() }
        _ = await host.handshake(windows: [], chats: [])
        #expect(await until { old.isOnline })
        let backend = LinkChatBackend(connection: old, provider: .claude, folder: "~/app", chatId: nil)
        #expect(backend.alwaysRefused == LinkPolicy.boxAlwaysAllowOld)
    }

    /// Adds `rules` to the project's local settings, as the CLI does for a `localSettings` update.
    static func keep(_ rules: [String], in folder: URL) {
        let file = folder.appendingPathComponent(".claude/settings.local.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = (FileManager.default.contents(atPath: file.path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        permissions["allow"] = (permissions["allow"] as? [String] ?? []) + rules
        settings["permissions"] = permissions
        try? JSONSerialization.data(withJSONObject: settings).write(to: file)
    }
}
