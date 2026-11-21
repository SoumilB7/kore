import AgentTools
import Foundation
@testable import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// What the owner's last pick of Full access may not reach (the review of 0.3.7): a chat the link,
/// a phone or Arsenal makes starts at most at its cap, never in the remembered mode; and a chat's
/// agent never allows commands in a chat it made, forked or woke.
extension AgentChannelTests {
    @MainActor
    @Suite("Full access: starting modes and self-approval", .serialized)
    struct FullAccessReachTests {
        typealias Rig = SendWakeTests.Rig

        /// New chats would start in Full access, Claude's and Codex's, were the last pick read.
        static func rememberFullAccess() {
            let defaults = UserDefaults(suiteName: "kore-full-access-reach")!
            defaults.removePersistentDomain(forName: "kore-full-access-reach")
            let memory = ModeMemory(defaults: defaults)
            memory.remember(ClaudeModes.fullAccess, for: .claude)
            memory.remember(CodexModes.fullAccess, for: .codex)
            ModeMemory.standIn = memory
        }

        func until(_ check: () -> Bool) async -> Bool {
            for _ in 0..<5000 where !check() { await Task.yield() }
            return check()
        }

        func call(_ rig: Rig, _ name: String, _ args: [String: Any]) async throws -> (ok: Bool, code: String?, message: String, chat: String?) {
            let channel = try #require(AgentChannel.current)
            let line = await channel.boxCall(chat: rig.caller.id.uuidString, name, args)
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let data = object["data"] as? [String: Any] ?? [:]
            return (object["ok"] as? Bool == true, object["code"] as? String, (data["message"] ?? object["message"]) as? String ?? "", data["chat"] as? String)
        }

        func chat(_ id: String?) -> Chat? { id.flatMap { AgentReads.chatsByID()[$0] } }

        // MARK: Starting modes

        @Test func aNewChatFromTheLinkOrAPhoneStartsInTheFirstModeOnABoardToo() throws {
            Self.rememberFullAccess()
            defer { ModeMemory.standIn = nil }
            let rig = try Rig([])
            defer { rig.finish() }
            // A chat the person starts here takes the last pick: the leak's source.
            let own = Chat(provider: .claude, folder: rig.home.folder)
            #expect(own.controls.mode == ClaudeModes.fullAccess)
            let board = try #require(rig.home.linkNewBoard())
            for provider in ["claude", "codex"] {
                let first = try #require(Registry.provider(provider)).modes[0].id
                let onBoard = try #require(rig.home.linkStartChat(provider: provider, model: nil, board: board, section: nil, group: nil))
                #expect(board.board?.orderedChats.contains { $0 === onBoard } == true)
                #expect(onBoard.controls.mode == first, "\(provider) on a board")
                let inStrip = try #require(rig.home.linkStartChat(provider: provider, model: nil, board: nil, section: nil, group: nil))
                #expect(inStrip.controls.mode == first, "\(provider) in the strip")
                #expect(rig.home.startChatFromLink(provider: provider)?.controls.mode == first)
            }
        }

        @Test func aLinksForkOfAFullAccessChatStartsAtAuto() throws {
            for (provider, full, cap) in [(ProviderDescriptor.claude, ClaudeModes.fullAccess, "auto"), (.codex, CodexModes.fullAccess, "approveForMe")] {
                let fork = Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp/kore-full-reach"), modeMemory: ModeMemory(defaults: nil))
                fork.controls.mode = full
                Workspace.linkCaps(fork)
                #expect(fork.controls.mode == cap, "\(provider.id)")
                // At or below Auto, a fork keeps its original's mode.
                fork.controls.mode = "acceptEdits"
                Workspace.linkCaps(fork)
                #expect(fork.controls.mode == (provider == .claude ? "acceptEdits" : cap))
            }
        }

        @Test func arsenalsNewWokenAndForkedChatsStartNoHigherThanTheCaller() async throws {
            Self.rememberFullAccess()
            defer { ModeMemory.standIn = nil }
            let rig = try Rig([SendWakeTests.login])
            defer { rig.finish() }
            rig.caller.setMode("auto", remember: false)
            await rig.caller.modeSettled()
            // New.
            let made = try await call(rig, "chat.new", ["provider": "claude"])
            #expect(made.ok, "\(made)")
            #expect(chat(made.chat)?.controls.mode == "auto")
            // Woken.
            let woken = try await rig.send("login page", "hello")
            #expect(woken.ok, "\(woken)")
            let opened = try #require(rig.tabs.first { $0.listedId == SendWakeTests.login.id })
            #expect(opened.controls.mode == "auto")
            // Forked (its own chat): in its mode, Auto.
            await rig.caller.start()
            let backend = try #require(WakeBackend.made.last)
            backend.sink.yield(.text("b1", .answer, "Done.", agent: .main))
            #expect(await until { rig.caller.transcript.entries.contains { $0.kind == .answer } })
            let forked = try await call(rig, "chat.fork", ["chat": rig.caller.id.uuidString])
            #expect(forked.ok, "\(forked)")
            #expect(chat(forked.chat)?.controls.mode == "auto")
            // A caller in Edit automatically: no higher than it.
            rig.caller.setMode("acceptEdits", remember: false)
            await rig.caller.modeSettled()
            let lower = try await call(rig, "chat.new", ["provider": "claude"])
            #expect(chat(lower.chat)?.controls.mode == "acceptEdits")
        }

        @Test func arsenalsNewCodexChatStartsNoHigherThanTheCaller() async throws {
            Self.rememberFullAccess()
            defer { ModeMemory.standIn = nil }
            let rig = try Rig([], callerCLI: "codex")
            defer { rig.finish() }
            rig.caller.setMode("approveForMe", remember: false)
            await rig.caller.modeSettled()
            let made = try await call(rig, "chat.new", ["provider": "codex"])
            #expect(made.ok, "\(made)")
            #expect(chat(made.chat)?.controls.mode == "approveForMe")
        }

        // MARK: Self-approval

        /// Kore's hook ask for `command`, as claude sends it in Auto, and its card.
        static func card(_ id: String, _ command: String = "sudo reboot") throws -> Approval {
            let json = #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"\#(command)"},"tool_use_id":"toolu_\#(id)","decision_reason_type":"hook","decision_reason":"Kore asks you first.","decision_reason_hook_event":"PreToolUse","decision_reason_hook_source":"settings"}}"#
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            let translator = ClaudeTranslator(folder: URL(fileURLWithPath: "/tmp/kore-full-reach"), sessionId: nil)
            translator.translate(.permissionRequest(PermissionRequest(id: id, value["request"] ?? .null)))
            return try #require(translator.take().events.compactMap { if case .approvalRequested(let a) = $0 { a } else { nil } }.first)
        }

        /// A plain permission card (not Auto's ask).
        static func permission(_ id: String) -> Approval {
            var card = Approval(id: id, title: "Run ls", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
            card.tool = "Bash"
            return card
        }

        @Test func aChatNeverAllowsCommandsInOneItMadeForkedOrWoke() async throws {
            ModeMemory.standIn = ModeMemory(defaults: nil)
            defer { ModeMemory.standIn = nil }
            let rig = try Rig([SendWakeTests.login])
            defer { rig.finish() }
            rig.caller.setMode("auto", remember: false)
            await rig.caller.modeSettled()
            await rig.caller.start()
            let backend = try #require(WakeBackend.made.last)
            let made = try #require(chat(try await call(rig, "chat.new", ["provider": "claude"]).chat))
            #expect(try await rig.send("login page", "hello").ok)
            let woken = try #require(rig.tabs.first { $0.listedId == SendWakeTests.login.id })
            backend.sink.yield(.text("b1", .answer, "Done.", agent: .main))
            #expect(await until { rig.caller.transcript.entries.contains { $0.kind == .answer } })
            let forked = try #require(chat(try await call(rig, "chat.fork", ["chat": rig.caller.id.uuidString]).chat))
            // One the person opened: its card is the agent's to run.
            #expect(rig.home.start(provider: "claude"))
            let unrelated = try #require(rig.home.activeTab.chat)

            for (name, target) in [("new", made), ("woken", woken), ("fork", forked), ("unrelated", unrelated)] {
                let ask = try Self.card("r-\(name)")
                target.approvals.apply(.approvalRequested(ask))
                let ran = try await call(rig, "cards.answer", ["chat": target.id.uuidString, "card": ask.id, "allow": true])
                let always = try await call(rig, "cards.answer", ["chat": target.id.uuidString, "card": ask.id, "always": true])
                let plain = Self.permission("p-\(name)")
                target.approvals.apply(.approvalRequested(plain))
                let allowed = try await call(rig, "cards.answer", ["chat": target.id.uuidString, "card": plain.id, "allow": true])
                if target === unrelated {
                    #expect(ran.ok && ran.message == "Ran once.", "\(ran)")
                    #expect(allowed.ok && allowed.message == "Allowed once.", "\(allowed)")
                } else {
                    for said in [ran, always, allowed] {
                        #expect(!said.ok && said.message == "Only you allow commands in a chat this one started.", "\(name): \(said)")
                    }
                    #expect(target.approvals.pending.map(\.id) == [ask.id, plain.id], "\(name)")
                    // Denying stays any driver's.
                    #expect(try await call(rig, "cards.answer", ["chat": target.id.uuidString, "card": plain.id, "deny": true]).ok)
                }
            }
            #expect(made.arsenalOrigins == [rig.caller.id.uuidString] && forked.arsenalOrigins == [rig.caller.id.uuidString])
        }

        @Test func aChatMadeByOneItMadeIsItsToo() {
            let folder = URL(fileURLWithPath: "/tmp/kore-full-reach")
            let a = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
            let b = Chat(provider: .codex, folder: folder, modeMemory: ModeMemory(defaults: nil))
            let c = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
            let other = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
            b.arsenalOrigins = Chat.origins(madeBy: a)
            c.arsenalOrigins = Chat.origins(madeBy: b)
            #expect(c.arsenalStarted(by: b) && c.arsenalStarted(by: a) && b.arsenalStarted(by: a))
            #expect(!c.arsenalStarted(by: other) && !a.arsenalStarted(by: b) && !a.arsenalStarted(by: c))
            // A box chat goes by its id on kore-host.
            c.hostKey = "box-chat-1"
            let d = Chat(provider: .claude, folder: folder, modeMemory: ModeMemory(defaults: nil))
            d.arsenalOrigins = Chat.origins(madeBy: c)
            #expect(d.arsenalOrigins == ["box-chat-1", b.id.uuidString, a.id.uuidString])
        }
    }
}
