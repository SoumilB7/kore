import AgentTools
import Foundation
@testable import KoreHost
import LinkProtocol
import Testing

/// `kore_new_chat` with `folder` on a box (the owner, for 0.3.7): one of the box's own folders
/// answered here at Act device, as the Mac answers; any other is the Mac's.
extension HostArsenalTests {
    @Test(arguments: ["claude", "codex"]) func aBoxOpensANewChatInAnotherOfItsFoldersAtActDevice(cli: String) async throws {
        let made = Made()
        let (rig, _, _) = try rig(made)
        defer { rig.finish() }
        // A second folder the box serves.
        let other = rig.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try HostConfig(folders: [rig.folder.path, other.path]).save(rig.paths.config)
        rig.restart()
        rig.host.sessionEnv["HOME"] = rig.root.path
        try rig.host.start()
        rig.host.services.backend = { _, _ in
            let backend = BusyStandIn()
            made.all.append(backend)
            return backend
        }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: cli, modelId: nil))
        let me = try caller(rig, hc)
        let socket = rig.paths.agentSocket.path
        let name = cli == "claude" ? "Claude" : "Codex"

        for tier in ["watch", "own", "drive"] {
            rig.host.arsenalSaid(tier, hc)
            let said = await ask("kore_new_chat", me, socket: socket, ["folder": other.path])
            #expect(!said.ok && said.text == AgentTools.folderTierLine(has: tier), "\(tier): \(said.text)")
        }
        rig.host.arsenalSaid("device", hc)
        let opened = Self.data(await ask("kore_new_chat", me, socket: socket, ["folder": other.path, "silent": true]).text)
        let id = try #require(opened["chat"] as? String, "\(opened)")
        #expect(opened["message"] as? String == "Opened a \(name) chat in other.")
        let chat = try #require(rig.host.chat(id))
        #expect(chat.record.folder == other.path && chat.arsenal == nil && chat.arsenalOrigins.first == hc.id)
        // As the box names it, too.
        let shown = Self.data(await ask("kore_new_chat", me, socket: socket, ["folder": HostDaemon.shownFolder(other.path)]).text)
        #expect(rig.host.chat(shown["chat"] as? String ?? "")?.record.folder == other.path, "\(shown)")
        // A folder the box doesn't serve is the Mac's: with no Mac, not connected.
        let elsewhere = await ask("kore_new_chat", me, socket: socket, ["folder": rig.root.path])
        #expect(!elsewhere.ok && elsewhere.text == HostDaemon.notConnected, "\(elsewhere.text)")
        #expect(rig.host.answersHere(hc, "kore_new_chat", ["folder": other.path], mac: true))
        #expect(!rig.host.answersHere(hc, "kore_new_chat", ["folder": rig.root.path], mac: true))
    }
}
