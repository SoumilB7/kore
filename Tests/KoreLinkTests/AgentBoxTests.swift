import AgentTools
import AppKit
import Foundation
import HostClient
import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// Link 1.6 on the Mac: a box chat's tool calls are decided here, under that chat's own tier and
/// limits, as its own caller on the agent channel would be. The box's word for which chat is
/// asking counts only for this Mac's own tab of it on that box.
@MainActor
@Suite("agent channel, box chats", .serialized)
struct AgentBoxTests {
    /// A Mac window with one chat, and a box window with one chat (`bc1` on the box), both on
    /// screen as far as the channel can tell.
    @MainActor
    final class Rig {
        let windows: [NSWindow]
        let mac: Workspace
        let box: Workspace
        let macChat: Chat
        let boxChat: Chat
        let connection: HostConnection

        init() throws {
            _ = AgentChannelTests.reset()
            AgentGrants.setEnabled(true)
            let alias = "kbt-\(UUID().uuidString.prefix(6))"
            connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: URL(fileURLWithPath: "/tmp/\(alias)")))
            HostConnection.adopt(connection)
            let binding = BoxBinding(alias: alias, folder: "/home/me/app")
            mac = Workspace(folder: URL(fileURLWithPath: "/tmp/\(alias)-mac"), restore: false)
            box = Workspace(folder: binding.folderURL, restore: false, box: binding)
            let claude = try #require(Registry.provider("claude"))
            macChat = Chat(provider: claude, folder: mac.folder)
            mac.tabs[0].chat = macChat
            boxChat = Chat(
                provider: claude, folder: box.folder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
                services: BoxChatServices(binding: binding, chatId: "bc1"))
            box.tabs[0].chat = boxChat
            windows = [mac, box].map { workspace in
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                workspace.window = window
                return window
            }
        }

        func call(_ tool: String, _ args: [String: JSONValue] = [:], chat: String = "bc1", on connection: HostConnection? = nil) async -> BoxToolResult {
            await AgentBoxCalls.answer(connection ?? self.connection, BoxToolCall(id: "a1", chatId: chat, tool: tool, args: .object(args)))
        }

        func finish() {
            AgentGrants.stopAll()
            mac.window = nil
            box.window = nil
        }
    }

    @Test func offIsRefusedAndEachTierHoldsAsHere() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        // Off, with the channel closed and with it open for another chat.
        let closed = await rig.call("kore_list_chats")
        #expect(!closed.ok && closed.code == "denied" && closed.text == AgentTools.offLine(box: true))
        AgentGrants.set(.drive, chat: rig.macChat.id.uuidString)
        #expect(AgentChannel.current != nil)
        let other = await rig.call("kore_new_chat")
        #expect(!other.ok && other.code == "denied")

        // Read: its window's chats and the Mac's chats that have Arsenal on, itself marked.
        AgentGrants.set(.watch, chat: rig.boxChat.id.uuidString)
        let listed = await rig.call("kore_list_chats")
        #expect(listed.ok)
        let chats = try #require((try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])?["chats"] as? [[String: Any]])
        #expect(Set(chats.compactMap { $0["id"] as? String }) == [rig.boxChat.id.uuidString, rig.macChat.id.uuidString])
        #expect(chats.first { $0["own"] as? Bool == true }?["id"] as? String == rig.boxChat.id.uuidString)
        // A box chat's folder is the box's: its name and the path there.
        #expect(chats.first { $0["own"] as? Bool == true }?["folder"] as? String == rig.connection.alias + ":/home/me/app")

        // Above Read: refused in the agent's terms, whatever another chat has.
        let options = await rig.call("kore_options")
        #expect(!options.ok && options.code == "tier" && options.text.contains("Act limited"))
        let opened = await rig.call("kore_new_chat")
        #expect(!opened.ok && opened.code == "tier")

        // Act limited: its own options, read from the box's lists.
        AgentGrants.set(.own, chat: rig.boxChat.id.uuidString)
        let own = await rig.call("kore_options")
        #expect(own.ok && own.text.contains(rig.boxChat.id.uuidString))
        // Turned off again: refused at once.
        AgentGrants.set(.off, chat: rig.boxChat.id.uuidString)
        #expect(await rig.call("kore_whoami").code == "denied")
    }

    @Test func onlyThisMacsTabOfThatChatOnThatBox() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        AgentGrants.set(.drive, chat: rig.boxChat.id.uuidString)
        AgentGrants.set(.drive, chat: rig.macChat.id.uuidString)
        #expect(await rig.call("kore_whoami").ok)
        // The same id from another box, the Mac chat's own id, and an id with no tab.
        let elsewhere = HostConnection(alias: "kbt-other", cache: HostCache(alias: "kbt-other", root: URL(fileURLWithPath: "/tmp/kbt-other")))
        for result in [
            await rig.call("kore_whoami", on: elsewhere), await rig.call("kore_whoami", chat: rig.macChat.id.uuidString),
            await rig.call("kore_whoami", chat: "nope"),
        ] {
            #expect(!result.ok && result.code == "no_chat")
        }
        // An unknown tool, and Kore's own arguments only.
        #expect(await rig.call("kore_shell").code == "unknown_command")
        let whoami = await rig.call("kore_whoami", ["chat": .string(rig.macChat.id.uuidString)])
        #expect(whoami.ok && whoami.text.contains(rig.boxChat.id.uuidString) && !whoami.text.contains(rig.macChat.id.uuidString))
    }

    @Test func newChatsCountTogetherOnTheBoxAndTheMac() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        AgentGrants.set(.drive, chat: rig.boxChat.id.uuidString)
        // On the box by default, in its window; with place mac, in the Mac's.
        for place in ["box", "mac", "box", "mac", "box"] {
            let result = await rig.call("kore_new_chat", place == "box" ? [:] : ["place": .string(place)])
            #expect(result.ok, "\(result.text)")
        }
        #expect(rig.box.tabs.compactMap(\.chat).filter { $0.services.onBox }.count == 4)
        #expect(rig.mac.tabs.compactMap(\.chat).count == 3)
        #expect(await rig.call("kore_new_chat", ["place": .string("mac")]).ok)
        // Six it opened are open, wherever they are.
        let seventh = await rig.call("kore_new_chat")
        #expect(!seventh.ok && seventh.code == "limit" && seventh.text.contains("\(AgentChannel.madeOpen)"))
        #expect(await rig.call("kore_new_chat", ["place": .string("elsewhere")]).code == "invalid")
    }
}
