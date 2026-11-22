import AgentTools
import AppKit
import Darwin
import Foundation
import HostClient
import KoreCore
@testable import KoreHost
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// A CLI that answers nothing on its own: Mac chats sent a message here start no real CLI.
@MainActor
final class ParityStandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { nil }
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {}
    func noteNextTurn(_ note: String) {}
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { true }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func compact(instructions: String) async throws {}
    func close() async { sink.finish() }
}

/// Arsenal 1:1 (the owner, 2026-11-18): a chat on a box has the same tools as a chat on the Mac,
/// at the same tiers, with the same answers, refusals and limits. Every tool is called at every
/// tier from a Mac chat (through the agent socket, as `kore mcp` calls it) and from a box chat
/// (as kore-host's `agent.call` reaches the Mac), each on a chat in its own window, and what each
/// agent reads is compared, its own ids and names aside. Inside the agent channel's suite: one
/// channel, one set of grants, so its tests take turns with these.
extension AgentChannelTests {
    @MainActor
    @Suite("Arsenal 1:1, Mac and box", .serialized)
    struct ArsenalParityTests {
        /// A Mac window and a box window, each with a caller and a chat it acts on.
        @MainActor
        final class Rig {
            let windows: [NSWindow]
            let mac: Workspace
            let box: Workspace
            let macCaller: Chat
            let macTarget: Chat
            let boxCaller: Chat
            let boxTarget: Chat
            let connection: HostConnection
            let binding: BoxBinding
            let socket: String

            init(_ cli: String) throws {
                socket = AgentChannelTests.socket(AgentChannelTests.reset())
                StorylineSeams.backend = { _, _ in ParityStandIn() }
                let alias = "kpt-\(UUID().uuidString.prefix(6))"
                connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: URL(fileURLWithPath: "/tmp/\(alias)")))
                HostConnection.adopt(connection)
                binding = BoxBinding(alias: alias, folder: "/home/me/app")
                // Both folders are "app": a refusal naming one reads the same.
                let macFolder = URL(fileURLWithPath: "/tmp/\(alias)/app")
                try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
                mac = Workspace(folder: macFolder, restore: false)
                box = Workspace(folder: binding.folderURL, restore: false, box: binding)
                let provider = try #require(Registry.provider(cli))
                let claude = try #require(Registry.provider("claude"))
                let (boxFolder, binding) = (box.folder, binding)
                func boxChat(_ provider: ProviderDescriptor, _ id: String) -> Chat {
                    Chat(
                        provider: provider, folder: boxFolder, modeMemory: ModeMemory(defaults: nil), compactMemory: AutoCompactMemory(defaults: nil),
                        services: BoxChatServices(binding: binding, chatId: id))
                }
                macCaller = Chat(provider: provider, folder: mac.folder)
                macTarget = Chat(provider: claude, folder: mac.folder)
                boxCaller = boxChat(provider, "bc1")
                boxTarget = boxChat(claude, "bc2")
                for (window, caller, target) in [(mac, macCaller, macTarget), (box, boxCaller, boxTarget)] {
                    window.tabs[0].chat = caller
                    let tab = ChatTab()
                    tab.chat = target
                    window.tabs.append(tab)
                }
                windows = [mac, box].map { workspace in
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    workspace.window = window
                    return window
                }
                AgentPasses.shared.register(macCaller.agentPass, pid: getppid())
            }

            /// The channel opened afresh (its limits new), the callers at `tier`, the chats they act on
            /// readable and idle (a tier's `kore_send` leaves them working: the stand-in never ends a turn).
            func open(_ tier: AgentTier) {
                for chat in [macTarget, boxTarget] { chat.status.setRunning(false) }
                AgentGrants.stopAll()
                ArsenalAsks.shared.reset()
                AgentGrants.setEnabled(true)
                for chat in [macTarget, boxTarget] { AgentGrants.set(.watch, chat: chat.id.uuidString) }
                for chat in [macCaller, boxCaller] { AgentGrants.set(tier, chat: chat.id.uuidString) }
            }

            func finish() {
                AgentPasses.shared.ended(getppid())
                AgentGrants.stopAll()
                ArsenalAsks.shared.reset()
                StorylineSeams.backend = nil
                mac.window = nil
                box.window = nil
                try? FileManager.default.removeItem(at: mac.folder.deletingLastPathComponent())
            }
        }

        /// What the agent reads: ok, and its text with each side's own ids and names put as tokens.
        struct Said: Equatable, CustomStringConvertible {
            let ok: Bool
            let text: String
            var description: String { "\(ok ? "ok" : "refused") \(text)" }
        }

        /// One call, its arguments with tokens each side fills in.
        struct Call: @unchecked Sendable {
            let tool: String
            let args: [String: Any]
        }

        /// Every tool, the destructive ones last; each side acts on the chat in its own window.
        static let calls: [Call] = [
            Call(tool: "kore_whoami", args: [:]), Call(tool: "kore_caps", args: [:]), Call(tool: "kore_list_chats", args: [:]),
            Call(tool: "kore_show_chat", args: ["chat": "{target}"]), Call(tool: "kore_read_chat", args: ["chat": "{target}", "last": 5]),
            Call(tool: "kore_pending", args: [:]), Call(tool: "kore_pending", args: ["chat": "{target}"]),
            Call(tool: "kore_history", args: [:]), Call(tool: "kore_history", args: ["folder": "{own}"]),
            Call(tool: "kore_options", args: [:]), Call(tool: "kore_rename", args: ["to": "p-{tier}-{side}"]),
            Call(tool: "kore_set_model", args: ["to": "no-such-model"]), Call(tool: "kore_set_effort", args: ["to": "high"]),
            Call(tool: "kore_set_fast", args: ["on": true]), Call(tool: "kore_lower_mode", args: ["to": "{mode}"]), Call(tool: "kore_compact", args: [:]),
            Call(tool: "kore_wait", args: ["chat": "{target}"]), Call(tool: "kore_stop", args: ["chat": "{target}"]),
            Call(tool: "kore_show_tab", args: ["chat": "{target}"]), Call(tool: "kore_answer", args: ["chat": "{target}", "card": "no-card"]),
            Call(tool: "kore_ask", args: ["chat": "{target}", "text": "which file?"]), Call(tool: "kore_reply", args: ["ask": "nope1234", "text": "this"]),
            Call(tool: "kore_fetch", args: ["path": ".env"]), Call(tool: "kore_close", args: ["chat": "zzzzzzzz"]),
            Call(tool: "kore_open_chat", args: ["session": "no-such-session"]), Call(tool: "kore_fork", args: ["chat": "."]),
            Call(tool: "kore_new_chat", args: [:]), Call(tool: "kore_send", args: ["chat": "{target}", "text": "hello"]),
            Call(tool: "kore_arrange", args: ["tabs": ["zzzzzzzz"], "to": "end"]),
        ]

        /// Fills in a side's tokens.
        static func filled(_ args: [String: Any], _ tokens: [String: String]) -> [String: Any] {
            args.mapValues { value in
                guard var text = value as? String else { return value }
                for (token, with) in tokens { text = text.replacingOccurrences(of: token, with: with) }
                return text
            }
        }

        /// A side's own ids, names and folder put as tokens, and either off line as one: a Codex chat on
        /// the Mac needs Full access to reach Kore, one on a box doesn't (its server runs outside the
        /// sandbox), so only the Mac's says so.
        static func said(_ ok: Bool, _ text: String, _ names: [(String, String)]) -> Said {
            var text = text
            for off in [AgentTools.offLine(box: false), AgentTools.offLine(box: true)] { text = text.replacingOccurrences(of: off, with: "{off}") }
            for (name, token) in names where !name.isEmpty { text = text.replacingOccurrences(of: name, with: token) }
            guard ok, let data = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return Said(ok: ok, text: text) }
            // A result's shape and its words; ids and lists are each side's own.
            return Said(ok: true, text: data.keys.sorted().joined(separator: ",") + " · " + (data["message"] as? String ?? ""))
        }

        func names(_ rig: Rig, mac: Bool) -> [(String, String)] {
            let (caller, target, window) = mac ? (rig.macCaller, rig.macTarget, rig.mac) : (rig.boxCaller, rig.boxTarget, rig.box)
            return [
                (caller.id.uuidString, "{caller}"), (target.id.uuidString, "{target}"), (AgentReads.short(caller.id.uuidString), "{caller}"),
                (AgentReads.short(target.id.uuidString), "{target}"), (window.boxFolder ?? LinkSnapshot.homeRelative(window.folder.path), "{folder}"),
                (mac ? "-mac" : "-box", "-{side}"),
            ]
        }

        func tokens(_ rig: Rig, mac: Bool, tier: AgentTier) -> [String: String] {
            let (caller, target, window) = mac ? (rig.macCaller, rig.macTarget, rig.mac) : (rig.boxCaller, rig.boxTarget, rig.box)
            return [
                "{target}": AgentReads.short(target.id.uuidString), "{own}": window.box?.folder ?? window.folder.path, "{mode}": caller.controls.mode,
                "{tier}": tier.rawValue, "{side}": mac ? "mac" : "box",
            ]
        }

        /// The Mac chat's calls on one connection, each as `kore mcp` makes it: its arguments, the tier
        /// check against what the welcome allows, and the answer as the agent reads it.
        func macCalls(_ rig: Rig, _ tier: AgentTier) async -> [Said] {
            let calls = Self.calls.map { Call(tool: $0.tool, args: Self.filled($0.args, tokens(rig, mac: true, tier: tier))) }
            let (path, pass) = (rig.socket, rig.macCaller.agentPass)
            let raw: [(Bool, String)] = await off {
                guard let client = AgentTestClient(path: path) else { return [] }
                defer { client.close() }
                guard let welcome = client.hello(pass: pass) else { return [] }
                if welcome["type"] as? String == "bye" {
                    let said = AgentTools.answer(welcome.object, box: false)
                    return calls.map { _ in (said.ok, said.text) }
                }
                let allowed = welcome["commands"] as? [String] ?? []
                return calls.enumerated().map { n, call in
                    guard let tool = AgentTools.tool(call.tool) else { return (false, "No such tool") }
                    guard allowed.contains(tool.command) else { return (false, AgentTools.tierLine(tool.command, has: welcome["tier"] as? String ?? "off")) }
                    guard let line = client.command("\(n)", tool.command, AgentTools.arguments(tool, call.args)) else { return (false, "no answer") }
                    let said = AgentTools.answer(line.object, box: false)
                    return (said.ok, said.text)
                }
            }
            let names = names(rig, mac: true)
            return raw.map { Self.said($0.0, $0.1, names) }
        }

        /// The box chat's calls, as kore-host passes each to the Mac.
        func boxCalls(_ rig: Rig, _ tier: AgentTier) async -> [Said] {
            let tokens = tokens(rig, mac: false, tier: tier)
            let names = names(rig, mac: false)
            var out: [Said] = []
            for (n, call) in Self.calls.enumerated() {
                let args = Self.filled(call.args, tokens)
                let json = try? JSONValue.parse(JSONSerialization.data(withJSONObject: args))
                let result = await AgentBoxCalls.answer(rig.connection, BoxToolCall(id: "p\(n)", chatId: "bc1", tool: call.tool, args: json))
                out.append(Self.said(result.ok, result.text, names))
            }
            return out
        }

        /// kore-host on its own, no Mac connected: a box with a caller and a chat it acts on, in a
        /// folder named as the Mac's are.
        @MainActor
        final class BoxAlone {
            let root: URL
            let folder: URL
            let host: HostDaemon
            let caller: HostChat
            let target: HostChat

            init(_ cli: String) throws {
                root = URL(fileURLWithPath: "/tmp/kpa-\(UUID().uuidString.prefix(6))")
                folder = root.appendingPathComponent("app")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let paths = HostPaths(environment: [
                    "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                    "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                ])
                try HostConfig(folders: [folder.path]).save(paths.config)
                host = HostDaemon(paths: paths)
                // Before anything reads the box's accounts: the scratch home.
                host.sessionEnv["HOME"] = root.path
                host.pastSessions = { _, _ in [] }
                host.services.backend = { _, _ in ParityStandIn() }
                caller = try #require(host.newChat(folder: folder.path, provider: cli, modelId: nil))
                target = try #require(host.newChat(folder: folder.path, provider: "claude", modelId: nil))
            }

            /// Limits new, the caller at `tier` (off: never given one), the chat it acts on readable and idle.
            func open(_ tier: AgentTier) {
                for hc in host.chats where hc !== caller { host.sleep(hc) }
                (host.boxArsenal.commands, host.boxArsenal.sends, host.boxArsenal.news, host.boxArsenal.made) = ([:], [:], [:], [:])
                host.arsenalSaid(tier == .off ? nil : tier.rawValue, caller)
                host.arsenalSaid("watch", target)
            }

            /// Each call as the box answers it with no Mac: here, or that the Mac isn't connected.
            func calls(_ tier: AgentTier) async -> [(here: Bool, said: Said)] {
                let names: [(String, String)] = [
                    (caller.id, "{caller}"), (target.id, "{target}"), (AgentRefs.short(caller.id), "{caller}"), (AgentRefs.short(target.id), "{target}"),
                    (HostDaemon.shownFolder(folder.path), "{folder}"), ("-box", "-{side}"),
                ]
                let tokens = [
                    "{target}": AgentRefs.short(target.id), "{own}": folder.path, "{mode}": HostMeta.modeID(caller), "{tier}": tier.rawValue, "{side}": "box",
                ]
                var out: [(Bool, Said)] = []
                for call in ArsenalParityTests.calls {
                    let args = ArsenalParityTests.filled(call.args, tokens)
                    guard host.answersHere(caller, call.tool, args, mac: false) else {
                        out.append((false, Said(ok: false, text: HostDaemon.notConnected)))
                        continue
                    }
                    let result = ArsenalRules.result(await host.arsenalCall(caller, call.tool, args), id: "")
                    out.append((true, ArsenalParityTests.said(result.ok, result.text, names)))
                }
                return out
            }

            func finish() {
                host.stop()
                try? FileManager.default.removeItem(at: root)
            }
        }

        /// The "box alone" column: every call kore-host answers itself reads as the Mac's answer for
        /// a box chat, at every tier; the rest (forks, opens, asks, files, tabs, chats it hasn't)
        /// say the Mac isn't connected. Its own calls are most of the table.
        @Test(arguments: ["claude", "codex"])
        func theBoxAloneAnswersAsTheMac(_ cli: String) async throws {
            let rig = try Rig(cli)
            defer { rig.finish() }
            let alone = try BoxAlone(cli)
            defer { alone.finish() }
            for tier in [AgentTier.off, .watch, .own, .drive, .device] {
                rig.open(tier)
                alone.open(tier)
                let onMac = await macCalls(rig, tier)
                let boxAlone = await alone.calls(tier)
                #expect(onMac.count == Self.calls.count && boxAlone.count == Self.calls.count, "\(cli) \(tier)")
                for (n, call) in Self.calls.enumerated() where n < min(onMac.count, boxAlone.count) {
                    if boxAlone[n].here {
                        #expect(onMac[n] == boxAlone[n].said, "\(cli) \(tier.rawValue) \(call.tool) \(call.args)")
                    } else {
                        #expect(boxAlone[n].said.text == HostDaemon.notConnected)
                    }
                }
                let here = boxAlone.filter(\.here).count
                #expect(tier < .drive || here >= 21, "\(cli) \(tier.rawValue): \(here) answered on the box")
            }
        }

        /// The Mac keeps a box chat's tier as it keeps its own chats', by its box and its id there, and
        /// brings it back when the tab comes back (Kore restarted), to say to the box with its first look.
        @Test func theMacKeepsABoxChatsTierByItsBoxAndId() throws {
            let rig = try Rig("claude")
            defer { rig.finish() }
            let kept = ArsenalMemory.defaults
            ArsenalMemory.defaults = UserDefaults(suiteName: "arsenal-parity-box-memory")!
            ArsenalMemory.clear()
            let allowed = Arsenal.shared.allowed
            defer {
                Arsenal.shared.turnOff(rig.boxCaller)
                ArsenalMemory.clear()
                ArsenalMemory.defaults = kept
                Arsenal.shared.setAllowed(allowed)
            }
            let key = try #require(ArsenalMemory.key(rig.boxCaller))
            #expect(key == "box:\(rig.connection.alias):bc1")
            Arsenal.shared.setAllowed(true)
            Arsenal.shared.choose(.drive, rig.boxCaller)
            #expect(ArsenalMemory.tier(key: key) == .drive)
            // As after a restart: the tab's chat has none until it's restored.
            rig.boxCaller.arsenal = nil
            Arsenal.shared.restore(rig.boxCaller)
            #expect(rig.boxCaller.arsenal == .drive)
            // Off is kept off.
            Arsenal.shared.turnOff(rig.boxCaller)
            #expect(ArsenalMemory.tier(key: key) == nil)
        }

        @Test func everyToolIsInTheTable() {
            #expect(Set(Self.calls.map(\.tool)) == Set(AgentTools.tools(box: true).map(\.name)))
            #expect(Set(Self.calls.map(\.tool)) == Set(AgentTools.tools().map(\.name)))
        }

        @Test(arguments: ["claude", "codex"])
        func everyToolAtEveryTierAnswersAlike(_ cli: String) async throws {
            let rig = try Rig(cli)
            defer { rig.finish() }
            for tier in [AgentTier.off, .watch, .own, .drive, .device] {
                rig.open(tier)
                let onMac = await macCalls(rig, tier)
                let onBox = await boxCalls(rig, tier)
                #expect(onMac.count == Self.calls.count && onBox.count == Self.calls.count, "\(cli) \(tier)")
                for (n, call) in Self.calls.enumerated() where n < min(onMac.count, onBox.count) {
                    #expect(onMac[n] == onBox[n], "\(cli) \(tier.rawValue) \(call.tool) \(call.args)")
                    // Refused for the tier exactly when the tool needs more than this one.
                    let command = try #require(AgentTools.tool(call.tool)).command
                    let needed = try #require(AgentTier(rawValue: AgentTools.tierNeeded(command)))
                    let byTier = onBox[n].text.hasPrefix("This needs Arsenal's")
                    #expect(tier == .off ? onBox[n].text == "{off}" : byTier == (tier < needed), "\(cli) \(tier.rawValue) \(call.tool): \(onBox[n])")
                }
            }
        }

        @Test func aBoxChatsCallsWaitAsLongAsTheMacsAndTheLinkMore() {
            for tool in AgentTools.tools(box: true) {
                #expect(HostToolServer.wait(tool.name, nil) == TimeInterval(AgentTools.answerWait(tool.command) + AgentTools.linkMargin), "\(tool.name)")
            }
            // A wait's own timeout counts on both, capped alike.
            #expect(HostToolServer.wait("kore_wait", .object(["timeout": .number(30)])) == TimeInterval(30 + 15 + AgentTools.linkMargin))
            #expect(AgentTools.answerWait("chat.wait", ["timeout": 9999]) == 315)
            // A file from a box, a fork, an open over the link: longer than a read.
            #expect(AgentTools.answerWait("file.fetch") > AgentTools.answerWait("chat.show"))
            #expect(AgentTools.answerWait("chat.reply") == AgentTools.answerWait("file.fetch"))
            #expect(AgentTools.answerWait("chat.fork") > AgentTools.answerWait("chat.new"))
        }

        @Test func aBoxChatHoldsAsManyCallsAtOnceAsAMacChat() async throws {
            let rig = try Rig("claude")
            defer { rig.finish() }
            rig.open(.drive)
            rig.boxTarget.status.setRunning(true)
            defer { rig.boxTarget.status.setRunning(false) }
            #expect(AgentReads.state(rig.boxTarget) == "working")
            let channel = try #require(AgentChannel.current)
            let target = rig.boxTarget.id.uuidString
            let caller = rig.boxCaller.id.uuidString
            // Waits on a working chat hold their places; one past the Mac's per process is turned away.
            var held: [Task<Data, Never>] = []
            for n in 0..<AgentSlots.perProcess {
                held.append(Task { await channel.boxCall(chat: caller, "chat.wait", ["chat": target, "timeout": 300 + n]) })
                await Task.yield()
            }
            let refused = await channel.boxCall(chat: caller, "chat.wait", ["chat": target])
            let said = AgentTools.answer((try JSONSerialization.jsonObject(with: refused)) as? [String: Any] ?? [:], box: true)
            #expect(!said.ok && said.code == "rate_limited" && said.text == AgentTools.tooManyLine)
            // The turn ends: every wait answers, and the places are free again.
            rig.boxTarget.status.setRunning(false)
            AgentGrants.stopAll()
            for task in held { _ = await task.value }
            rig.open(.drive)
            let again = try #require(AgentChannel.current)
            let whoami = await again.boxCall(chat: caller, "agent.whoami", [:])
            #expect(AgentTools.answer((try JSONSerialization.jsonObject(with: whoami)) as? [String: Any] ?? [:], box: true).ok)
        }

        /// What differs on purpose: a box chat opens chats on its box or the Mac (`place`). Asks go
        /// both ways alike (the owner, 2026-11-19); files from another device, both ways, at Act
        /// device only (the owner, 2026-11-20).
        @Test func whatABoxChatDoesDifferently() async throws {
            let rig = try Rig("claude")
            defer { rig.finish() }
            rig.open(.drive)
            AgentGrants.set(.drive, chat: rig.macTarget.id.uuidString)
            #expect(!AgentTools.tool("kore_new_chat")!.args.contains { $0.0 == "place" })
            #expect(AgentTools.tool("kore_new_chat", box: true)!.args.contains { $0.0 == "place" })
            func call(_ tool: String, _ args: [String: JSONValue]) async -> BoxToolResult {
                await AgentBoxCalls.answer(rig.connection, BoxToolCall(id: "d", chatId: "bc1", tool: tool, args: .object(args)))
            }
            // Box to Mac and Mac to box: the same answer, the same rules after it.
            AgentGrants.set(.drive, chat: rig.boxTarget.id.uuidString)
            let asked = await call("kore_ask", ["chat": .string(AgentReads.short(rig.macTarget.id.uuidString)), "text": .string("q")])
            #expect(asked.ok && asked.text.contains("Asked"), "\(asked.text)")
            let channel = try #require(AgentChannel.current)
            let line = await channel.boxCall(chat: rig.macCaller.id.uuidString, "chat.ask", ["chat": AgentReads.short(rig.boxTarget.id.uuidString), "text": "q"])
            let back = AgentTools.answer((try JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:], box: false)
            #expect(back.ok && back.text.contains("Asked"), "\(back.text)")
            for said in [asked.text, back.text] {
                let data = try #require((try JSONSerialization.jsonObject(with: Data(said.utf8))) as? [String: Any])
                #expect(Set(data.keys) == ["ask", "chat", "message"])
            }
            // The target chat isn't Act unlimited: refused alike.
            AgentGrants.set(.watch, chat: rig.macTarget.id.uuidString)
            let notDrive = await call("kore_ask", ["chat": .string(AgentReads.short(rig.macTarget.id.uuidString)), "text": .string("q")])
            #expect(!notDrive.ok && notDrive.text.hasPrefix("Not asked:") && notDrive.text.hasSuffix("isn't Act unlimited"), "\(notDrive.text)")
            // A file from another device: refused at Act unlimited, box to Mac and Mac to box.
            let notes = rig.mac.folder.appendingPathComponent("notes.md")
            try Data("notes".utf8).write(to: notes)
            let needs = "Not fetched: " + ArsenalFetch.Refusal.otherDevice.line
            func fromBox(_ path: String) async throws -> AgentTools.Object {
                let line = await channel.boxCall(chat: rig.macCaller.id.uuidString, "file.fetch", ["path": rig.connection.alias + ":" + path])
                return (try JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            }
            let fetched = await call("kore_fetch", ["path": .string("mac:" + notes.path)])
            #expect(!fetched.ok && fetched.text == needs, "\(fetched.text)")
            let down = AgentTools.answer(try await fromBox("/home/me/app/notes.md"), box: false)
            #expect(!down.ok && down.text == needs, "\(down.text)")
            // At Act device both pass the tier to fetch's own rules (each file here fails one before
            // any copy: this box isn't online to carry it; ArsenalFetchTests carries them).
            AgentGrants.set(.device, chat: rig.boxCaller.id.uuidString)
            AgentGrants.set(.device, chat: rig.macCaller.id.uuidString)
            let missing = rig.mac.folder.appendingPathComponent("none.md").path
            let up = await call("kore_fetch", ["path": .string("mac:" + missing)])
            #expect(!up.ok && up.text == "Not fetched: \(missing) isn't there", "\(up.text)")
            let downAtDevice = AgentTools.answer(try await fromBox("/etc/hosts"), box: false)
            #expect(!downAtDevice.ok && downAtDevice.text.hasPrefix("Not fetched: /etc/hosts is outside"), "\(downAtDevice.text)")
            AgentGrants.set(.drive, chat: rig.boxCaller.id.uuidString)
            AgentGrants.set(.drive, chat: rig.macCaller.id.uuidString)
            // Into the other CLI: Import carries a history file on this Mac, so a box's chat forks into its own.
            let across = await call("kore_fork", ["chat": .string("."), "provider": .string("codex")])
            #expect(!across.ok && across.text.contains("forks into its own CLI only"))
            // Its own folder named as the box names it, or as the chat list shows it; another box
            // folder by its device.
            for folder in ["/home/me/app", rig.box.boxFolder ?? "-", "."] {
                let history = await call("kore_history", ["folder": .string(folder)])
                #expect(history.ok, "\(folder): \(history.text)")
            }
            // The Mac's folder, as the chat list shows it, with Act unlimited.
            let macHistory = await call("kore_history", ["folder": .string(LinkSnapshot.homeRelative(rig.mac.folder.path))])
            #expect(macHistory.ok, "\(macHistory.text)")
        }
    }
}
