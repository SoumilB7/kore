@testable import AgentTools
import AppKit
import Foundation
import HostClient
@testable import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// Tab groups and the window view over the agent channel (the owner via Kore-main, 2026-11-24):
/// `group` on new chats, `chats.list`'s windows, `tabs.arrange` at Act limited, from a Claude
/// chat and a Codex one alike; and what they cost an agent's context.
extension AgentChannelTests {
    @MainActor
    @Suite("tab groups over the channel", .serialized)
    struct ArsenalTabsChannelTests {
        typealias Rig = SendWakeTests.Rig

        func rig(_ cli: String, tier: AgentTier) throws -> (Rig, () -> Void) {
            let rig = try Rig([], callerCLI: cli)
            AgentGrants.set(tier, chat: rig.caller.id.uuidString)
            let saved = ArsenalWindows.front
            ArsenalWindows.front = { _ in }
            return (rig, {
                ArsenalWindows.front = saved
                rig.finish()
            })
        }

        func call(_ rig: Rig, _ name: String, _ args: [String: Any] = [:]) async throws -> (ok: Bool, data: [String: Any], message: String) {
            let channel = try #require(AgentChannel.current)
            let line = await channel.boxCall(chat: rig.caller.id.uuidString, name, args)
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let data = object["data"] as? [String: Any] ?? [:]
            return (object["ok"] as? Bool == true, data, (data["message"] ?? object["message"]) as? String ?? "")
        }

        @Test(arguments: ["claude", "codex"]) func silentOpensInAGroupThenListedShownAndUngrouped(cli: String) async throws {
            let (rig, done) = try rig(cli, tier: .drive)
            defer { done() }
            var made: [String] = []
            for n in 1...2 {
                let said = try await call(rig, "chat.new", ["silent": true, "group": "Workers", "text": "job \(n)"])
                #expect(said.ok && said.message.contains("In group “Workers”."), "\(said.message)")
                made.append(try #require(said.data["short"] as? String))
            }
            #expect(rig.home.activeTab.chat === rig.caller, "silent: the caller's tab stays in front")
            let list = try await call(rig, "chats.list")
            let window = try #require((list.data["windows"] as? [[String: Any]])?.first { $0["here"] as? Bool == true })
            let group = try #require((window["groups"] as? [[String: Any]])?.first)
            #expect(group["name"] as? String == "Workers" && group["tabs"] as? [String] == made)
            #expect(group["by"] as? String == AgentReads.short(rig.caller.id.uuidString))
            #expect(window["selected"] as? String == AgentReads.short(rig.caller.id.uuidString))
            // Shown: out of the group, in front; the answer is the order.
            let shown = try await call(rig, "tabs.arrange", ["tabs": [made[1]], "show": true])
            #expect(shown.ok && shown.message.contains("*\(made[1])") && shown.message.contains("[Workers: \(made[0])]"), "\(shown.message)")
            #expect(rig.home.activeTab.chat.map { AgentReads.short($0.id.uuidString) } == made[1])
            let ungrouped = try await call(rig, "tabs.arrange", ["group": "Workers", "ungroup": true])
            #expect(ungrouped.ok && !ungrouped.message.contains("["), "\(ungrouped.message)")
            #expect(rig.home.tabGroups.isEmpty && rig.home.tabs.count == 3, "groups empty \(rig.home.tabGroups.isEmpty), \(NewFolderSilentTests.state(rig.home, nil))")
        }

        @Test func arrangingIsActLimitedAndGroupingANewChatStaysActUnlimited() async throws {
            let (rig, done) = try rig("claude", tier: .watch)
            defer { done() }
            let read = try await call(rig, "tabs.arrange", ["tabs": ["."], "to": "end"])
            #expect(!read.ok && read.message == AgentChannel.message(.tier))
            AgentGrants.set(.own, chat: rig.caller.id.uuidString)
            let own = try await call(rig, "tabs.arrange", ["tabs": [AgentReads.short(rig.caller.id.uuidString)], "group": "Mine"])
            #expect(own.ok && own.message.contains("[Mine: *"), "\(own.message)")
            let new = try await call(rig, "chat.new", ["group": "Mine"])
            #expect(!new.ok)
            // Showing a tab brings a window forward: kore_show_tab's job, at its tier (Act unlimited).
            let shown = try await call(rig, "tabs.arrange", ["tabs": [AgentReads.short(rig.caller.id.uuidString)], "show": true])
            #expect(!shown.ok && shown.message == AgentChannel.message(.tier), "\(shown.message)")
            #expect(AgentTools.tierNeeded("tabs.arrange") == "own" && AgentCommand.arrange.tier == .own)
        }

        @Test func aWindowCanBeAskedForAloneAndAnUnknownOneSaysSo() async throws {
            let (rig, done) = try rig("claude", tier: .own)
            defer { done() }
            let one = try await call(rig, "chats.list", ["window": "app"])
            #expect(one.ok && (one.data["windows"] as? [[String: Any]])?.count == 1)
            let none = try await call(rig, "chats.list", ["window": "nowhere"])
            #expect(!none.ok && none.message == "No Kore window is called nowhere.")
        }

        /// What it costs: the tool list an agent loads, and a list of 11 tabs with two groups.
        @Test func theToolsAndTheWindowViewStaySmall() throws {
            func bytes(_ object: Any) -> Int { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))?.count ?? 0 }
            let after = AgentTools.tools().map(AgentTools.describe)
            let before = AgentTools.tools().filter { $0.command != "tabs.arrange" }.map { tool in
                AgentTools.Tool(
                    name: tool.name, command: tool.command,
                    description: tool.command == "chats.list"
                        ? "List the chats open in Kore (its tabs): id, title, CLI, folder, state (working, idle, needs-you), mode, model, waiting cards." : tool.description,
                    args: tool.args.filter { !["group", "window"].contains($0.0) }, required: tool.required)
            }.map(AgentTools.describe)
            let arrange = try #require(AgentTools.tool("kore_arrange")).args
            print("tools/list bytes: before \(bytes(before)), after \(bytes(after)), +\(bytes(after) - bytes(before))")
            #expect(bytes(after) - bytes(before) < 2_000)
            // One line each.
            #expect(arrange.allSatisfy { !$0.2.contains("\n") && $0.2.count <= 160 })

            let chats = (0..<11).map { n in
                AgentChat(
                    id: UUID().uuidString, short: String(format: "%08x", n * 2_654_435_761 % 0xffff_ffff), title: "A chat about part \(n)", provider: n % 3 == 0 ? "codex" : "claude",
                    folder: "~/Code/Projects/kore", window: "kore", state: "idle", mode: "auto", modeLabel: "Auto", model: "Opus 5.5", queued: 0, cards: 0)
            }
            let ids = chats.map(\.short)
            let window = AgentWindow(
                name: "kore", selected: ids[0], tabs: ids,
                groups: [.init(name: "Workers", by: ids[0], folded: nil, tabs: Array(ids[1...4])), .init(name: "Mine", by: "user", folded: true, tabs: Array(ids[7...8]))],
                other: nil, here: true)
            let plain = try JSONEncoder().encode(AgentChats(chats: chats))
            let full = try JSONEncoder().encode(AgentChats(chats: chats, windows: [window]))
            print("chats.list bytes, 11 tabs: before \(plain.count), after \(full.count), +\(full.count - plain.count)")
            #expect(full.count - plain.count < 400)
        }
    }
}
