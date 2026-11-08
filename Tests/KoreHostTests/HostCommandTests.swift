import AgentTools
import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// `kore` on a box (the owner, 2026-11-19): the Mac's `kore` commands in a box chat's shell, each
/// one tool call to the Mac through kore-host, with the same arguments, tiers and exit codes.
extension HostToolTests {
    /// One `kore` command as a box chat's shell runs it, off the main actor (it blocks on the socket).
    nonisolated func kore(_ arguments: [String], _ env: [String: String]) async -> Int32 {
        await Task.detached { HostCommand.run(arguments, environment: env) }.value
    }

    @Test func aBoxChatHasKoreOnItsPath() async throws {
        let made = Made()
        let (rig, grant, hc) = try rig(made)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(try await send(client, hc, "one", arsenal: "watch").ok)
        let server = try #require(made.backends.first?.options.agentServer)
        let folder = try #require(server.pathFolder)
        // A link named kore to kore-host itself, in the runtime folder, only this user's.
        #expect(folder == rig.paths.runtime.appendingPathComponent("bin").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/kore") == rig.host.mcpCommand.path)
        #expect((try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int) == 0o700)
        // A link left pointing elsewhere (the binary moved) is made again.
        try FileManager.default.removeItem(atPath: folder + "/kore")
        try FileManager.default.createSymbolicLink(atPath: folder + "/kore", withDestinationPath: "/nowhere")
        #expect(rig.host.koreFolder() == folder)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/kore") == rig.host.mcpCommand.path)
    }

    @Test func koreArgumentsAreTheMacs() async throws {
        // Usage, a command that isn't one, and the Mac's own (opening Kore, its logs).
        #expect(await kore(["help"], [:]) == 0)
        #expect(await kore(["show"], [:]) == 2)
        #expect(await kore(["fast", "maybe"], [:]) == 2)
        #expect(await kore(["new", "--place"], [:]) == 2)
        #expect(await kore(["logs"], [:]) == 2)
        #expect(await kore(["."], [:]) == 2)
        // Outside a chat kore-host started: refused, as the Mac's is with no Kore.
        #expect(await kore(["ls"], [:]) == 5)
        // A follow is the Mac's: said before anything is asked.
        let env = ["KORE_AGENT_SOCKET": "/tmp/none.sock", KoreReach.chatVariable: "c1", "KORE_AGENT_PASS": "p"]
        #expect(await kore(["log", ".", "-f"], env) == 1)
        #expect(throws: AgentFailure.self) { try HostCommandClient(env).run("tx.follow", ["chat": "."]) }
        // No daemon at the socket.
        #expect(await kore(["ls"], env) == 5)
        // Every command the Mac's kore sends is one of the box's tools.
        let commands = Set(AgentTools.tools(box: true).map(\.command))
        for command in ["agent.whoami", "agent.caps", "chats.list", "chat.show", "tx.read", "cards.list", "history.list", "chat.options", "chat.new", "chat.fork",
            "chat.wait", "chat.send", "chat.stop", "tab.show", "chat.open", "chat.close", "chat.ask", "chat.reply", "file.fetch", "cards.answer"]
            + AgentTools.ownCommands
        {
            #expect(commands.contains(command), "\(command)")
        }
    }

    @Test func aKoreCommandGoesToTheMacAsItsTool() async throws {
        let made = Made()
        let (rig, grant, hc) = try rig(made)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        defer { client.close() }
        #expect(try await send(client, hc, "one", arsenal: "drive").ok)
        let env = ["KORE_AGENT_SOCKET": rig.paths.agentSocket.path, KoreReach.chatVariable: hc.id, "KORE_AGENT_PASS": try #require(hc.chat?.agentPass)]

        // kore new --place mac "hi": kore_new_chat with its arguments, and the Mac's answer.
        async let opened = kore(["new", "--codex", "--place", "mac", "hi"], env)
        try await until { !calls(client).isEmpty }
        let call = try #require(calls(client).first)
        #expect(call.chatId == hc.id && call.tool == "kore_new_chat")
        #expect(call.args?["provider"]?.string == "codex" && call.args?["place"]?.string == "mac" && call.args?["text"]?.string == "hi")
        client.send(BoxToolResult(id: call.id, ok: true, text: #"{"chat":"c2","message":"Opened a Codex chat. Sent.","short":"c2"}"#))
        #expect(await opened == 0)

        // Above the tier: refused, exit 5 as on the Mac.
        async let refused = kore(["send", "c2", "go"], env)
        try await until { calls(client).count == 2 }
        #expect(calls(client)[1].tool == "kore_send")
        client.send(BoxToolResult(id: calls(client)[1].id, ok: false, code: "tier", text: "This needs Arsenal's Act unlimited tier."))
        #expect(await refused == 5)

        // A read's data, as the Mac's kore reads it.
        let reading = Task.detached { () -> String? in
            let data = try? HostCommandClient(env).run("chats.list", [:])
            return ((data?["chats"] as? [[String: Any]])?.first?["short"]) as? String
        }
        try await until { calls(client).count == 3 }
        client.send(BoxToolResult(id: calls(client)[2].id, ok: true, text: #"{"chats":[{"id":"c2","short":"c2"}]}"#))
        #expect(await reading.value == "c2")
    }
}
