import AgentTools
import AppKit
import Darwin
import Foundation
import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// A CLI for a woken chat: it records how it was launched and what it was sent, and starts as the
/// test says (at once, never, or held until the chat closes). No process, no clock.
@MainActor
final class WakeBackend: ChatBackend {
    enum Start { case ok, fail, hold }
    static var start = Start.ok
    static var made: [WakeBackend] = []

    let provider: String
    let resumed: String?
    var sent: [String] = []
    var held: CheckedContinuation<Void, Error>?
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var sessionId: String? { resumed }

    struct NoCLI: LocalizedError {
        var errorDescription: String? { "claude: command not found" }
    }

    init(provider: String, resumed: String?) {
        self.provider = provider
        self.resumed = resumed
        (events, sink) = AsyncStream.makeStream()
    }

    func start() async throws {
        switch Self.start {
        case .ok: return
        case .fail: throw NoCLI()
        case .hold: try await withCheckedThrowingContinuation { held = $0 }
        }
    }

    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool {
        sent.append(text)
        return true
    }

    func close() async {
        sink.finish()
        held?.resume(throwing: CancellationError())
        held = nil
    }

    func noteNextTurn(_ note: String) {}
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
}

/// `kore send` to a chat that isn't open (the owner, 2026-11-20): found in History, opened as
/// `chat.open` opens it, then sent; refused, with nothing opened, when it can't be.
extension AgentChannelTests {
    @MainActor
    @Suite("send wakes a dormant chat", .serialized)
    struct SendWakeTests {
        /// One past chat of each CLI (and those a test adds) in a Mac window's History, a caller in
        /// that window at Act unlimited, and the scripted CLI the woken chat runs.
        @MainActor
        final class Rig {
            let root: URL
            let home: Workspace
            var windows: [NSWindow] = []
            let caller: Chat
            var past: [URL: [SessionSummary]] = [:]
            let socket: String

            init(_ past: [SessionSummary], callerCLI: String = "claude") throws {
                socket = AgentChannelTests.socket(AgentChannelTests.reset())
                root = URL(fileURLWithPath: "/tmp/ksw-\(UUID().uuidString.prefix(6))")
                let folder = root.appendingPathComponent("app")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                WakeBackend.start = .ok
                WakeBackend.made = []
                StorylineSeams.backend = { provider, options in
                    let backend = WakeBackend(provider: provider, resumed: options.resume?.id)
                    WakeBackend.made.append(backend)
                    return backend
                }
                ChatEngine.startRetries.value = []
                home = Workspace(folder: folder, restore: false)
                caller = Chat(provider: try #require(Registry.provider(callerCLI)), folder: folder)
                home.tabs[0].chat = caller
                self.past[folder.standardizedFileURL] = past
                // History is the rig's alone: no CLI's own list is read.
                StorylineSeams.sessions = { [weak self] provider, folder in
                    let rows = self?.past[folder.standardizedFileURL] ?? []
                    return (own: false, extra: rows.filter { Registry.provider(for: $0.agent).id == provider })
                }
                show(home)
                AgentPasses.shared.register(caller.agentPass, pid: getppid())
                AgentGrants.setEnabled(true)
                AgentGrants.set(.drive, chat: caller.id.uuidString)
            }

            func show(_ workspace: Workspace) {
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                workspace.window = window
                windows.append(window)
            }

            /// Another folder's window, with its own History.
            func other(_ name: String, _ past: [SessionSummary]) throws -> Workspace {
                let folder = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.past[folder.standardizedFileURL] = past
                let workspace = Workspace(folder: folder, restore: false)
                show(workspace)
                return workspace
            }

            func finish() {
                AgentPasses.shared.ended(getppid())
                AgentGrants.stopAll()
                StorylineSeams.backend = nil
                StorylineSeams.sessions = nil
                ChatEngine.startRetries.value = [.seconds(2), .seconds(5), .seconds(10)]
                WakeBackend.start = .ok
                for workspace in Workspace.all.allObjects where workspace.folder.path.hasPrefix(root.path) { workspace.window = nil }
                try? FileManager.default.removeItem(at: root)
            }

            /// One `chat.send` as the caller's agent makes it: ok, its code, and what it says.
            func send(_ chat: String, _ text: String, folder: String? = nil) async throws -> (ok: Bool, code: String?, message: String, short: String?) {
                var args: [String: Any] = ["chat": chat, "text": text]
                if let folder { args["folder"] = folder }
                let channel = try #require(AgentChannel.current)
                let line = await channel.boxCall(chat: caller.id.uuidString, "chat.send", args)
                return Self.said(line)
            }

            static func said(_ line: Data) -> (ok: Bool, code: String?, message: String, short: String?) {
                let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                let data = object["data"] as? [String: Any] ?? [:]
                return (object["ok"] as? Bool == true, object["code"] as? String, (data["message"] ?? object["message"]) as? String ?? "", data["short"] as? String)
            }

            var tabs: [Chat] { home.tabs.compactMap(\.chat) }
        }

        static let login = SessionSummary(id: "5e55f00d-1111-4222-8333-000000000001", agent: .claude, title: "Fix the login page", updated: Date(timeIntervalSince1970: 1_790_000_000))
        static let button = SessionSummary(id: "7a8b9c0d-1111-4222-8333-000000000002", agent: .claude, title: "Fix the login button", updated: Date(timeIntervalSince1970: 1_789_000_000))
        static let thread = SessionSummary(id: "019a2b3c-4d5e-7f00-8000-000000000003", agent: .codex, title: "Refunds plan", updated: Date(timeIntervalSince1970: 1_788_000_000))

        /// Polls the main actor's other work along, never the clock: true once `check` holds.
        func until(_ check: () -> Bool) async -> Bool {
            for _ in 0..<5000 where !check() { await Task.yield() }
            return check()
        }

        @Test func aDormantClaudeChatOpensResumedThenTakesTheMessage() async throws {
            let rig = try Rig([Self.login, Self.button, Self.thread])
            defer { rig.finish() }
            let said = try await rig.send("login page", "hello there")
            #expect(said.ok && said.message == "Opened “Fix the login page”. Sent.", "\(said)")
            // One tab more, its CLI's session resumed, its Arsenal off, the message its CLI's.
            #expect(rig.tabs.count == 2)
            let woken = try #require(rig.tabs.last)
            #expect(said.short == AgentReads.short(woken.id.uuidString))
            #expect(woken.provider.id == "claude" && woken.listedId == Self.login.id && woken.arsenalByAgent)
            #expect(AgentGrants.tier(chat: woken.id.uuidString) == .off)
            let backend = try #require(WakeBackend.made.first { $0.resumed == Self.login.id })
            #expect(backend.provider == "claude" && backend.sent == ["hello there"])
            #expect(WakeBackend.made.filter { $0.resumed == Self.login.id }.count == 1)
            // Open now: by its CLI session id (or the start of it) it goes as to any open chat, as before.
            let again = try await rig.send("5e55f00d", "and this")
            #expect(again.ok && again.short == nil && again.message.hasPrefix("Queued"), "\(again)")
            #expect(rig.tabs.count == 2)
            // Its Kore short id, as kore ls shows it: the same.
            let third = try await rig.send(AgentReads.short(woken.id.uuidString), "one more")
            #expect(third.ok && third.short == nil, "\(third)")
        }

        @Test func aDormantCodexChatOpensResumedThenTakesTheMessage() async throws {
            let rig = try Rig([Self.login, Self.thread], callerCLI: "codex")
            defer { rig.finish() }
            let said = try await rig.send("019a2b3c", "plan the refunds fix")
            #expect(said.ok && said.message == "Opened “Refunds plan”. Sent.", "\(said)")
            let woken = try #require(rig.tabs.last)
            #expect(woken.provider.id == "codex" && woken.listedId == Self.thread.id)
            let backend = try #require(WakeBackend.made.first { $0.resumed == Self.thread.id })
            #expect(backend.provider == "codex" && backend.sent == ["plan the refunds fix"])
        }

        /// Two sends to the same dormant chat on one line each, before it has opened: it opens once,
        /// and its messages reach its CLI in the order they came.
        @Test func sendsWhileItOpensWaitForItInOrder() async throws {
            let rig = try Rig([Self.login])
            defer { rig.finish() }
            let (path, pass) = (rig.socket, rig.caller.agentPass)
            let lines: [AgentLine] = await off {
                guard let client = AgentTestClient(path: path) else { return [] }
                defer { client.close() }
                guard client.hello(pass: pass)?["type"] as? String == "welcome" else { return [] }
                // Both in one write: Kore reads them in one go, before the first has opened anything.
                var data = Data()
                for (id, text) in [("1", "one"), ("2", "two"), ("3", "three")] {
                    data += try! JSONSerialization.data(withJSONObject: ["type": "cmd", "id": id, "cmd": "chat.send", "args": ["chat": "login page", "text": text]])
                    data.append(0x0A)
                }
                _ = data.withUnsafeBytes { write(client.fd, $0.baseAddress, $0.count) }
                return (0..<3).compactMap { _ in client.next() }
            }
            #expect(lines.count == 3)
            let byId = Dictionary(lines.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            let first = try #require((byId["1"]?["data"] as? [String: Any])?["message"] as? String)
            #expect(first == "Opened “Fix the login page”. Sent.")
            for id in ["2", "3"] {
                #expect(byId[id]?["ok"] as? Bool == true, "\(String(describing: byId[id]?.object))")
                #expect(((byId[id]?["data"] as? [String: Any])?["message"] as? String)?.hasPrefix("Opened") == false)
            }
            #expect(rig.tabs.count == 2)
            let backends = WakeBackend.made.filter { $0.resumed == Self.login.id }
            #expect(backends.count == 1 && backends.first?.sent == ["one", "two", "three"])
        }

        /// Its CLI doesn't start: the caller is told why, and the message is in the chat's composer.
        @Test func aCLIThatDoesntStartSaysWhyAndKeepsTheMessage() async throws {
            let rig = try Rig([Self.login])
            defer { rig.finish() }
            WakeBackend.start = .fail
            let said = try await rig.send("Fix the login page", "hello there")
            #expect(!said.ok && said.code == "refused")
            #expect(said.message == "Opened “Fix the login page”. Not sent: Claude couldn't take it (claude: command not found). The message is back in its composer.", "\(said.message)")
            let woken = try #require(rig.tabs.last)
            #expect(woken.listedId == Self.login.id && woken.draft == "hello there")
        }

        /// The chat closed while its message waited for its CLI: said so, not left hanging.
        @Test func aChatClosedBeforeItsCLITookTheMessageSaysSo() async throws {
            let rig = try Rig([Self.login])
            defer { rig.finish() }
            WakeBackend.start = .hold
            let pending = Task { try await rig.send("login page", "hello there") }
            #expect(await until { WakeBackend.made.contains { $0.held != nil } })
            let tab = try #require(rig.home.tabs.last)
            #expect(tab.chat?.listedId == Self.login.id)
            rig.home.close(tab)
            let said = try await pending.value
            #expect(!said.ok && said.code == "no_chat")
            #expect(said.message == "Opened “Fix the login page”. It closed before its CLI took the message: not sent.", "\(said.message)")
        }

        @Test func titlesSeveralShareAreRefusedWithTheirIDs() async throws {
            let rig = try Rig([Self.login, Self.button])
            defer { rig.finish() }
            let said = try await rig.send("fix the login", "hello")
            #expect(!said.ok && said.code == "ambiguous")
            #expect(said.message.contains("5e55f00d “Fix the login page”") && said.message.contains("7a8b9c0d “Fix the login button”"), "\(said.message)")
            #expect(said.message.hasSuffix("nothing was sent."))
            #expect(rig.tabs.count == 1 && WakeBackend.made.allSatisfy { $0.sent.isEmpty })
            // Unknown: one line, nothing opened.
            let unknown = try await rig.send("no such chat", "hello")
            #expect(!unknown.ok && unknown.code == "no_chat" && unknown.message == "No open or past chat matches “no such chat” in \(LinkSnapshot.homeRelative(rig.home.folder.path)).")
            #expect(rig.tabs.count == 1)
            // An open chat's title wins over History's: sent there, nothing woken.
            let tab = ChatTab()
            let open = Chat(provider: try #require(Registry.provider("claude")), folder: rig.home.folder)
            tab.chat = open
            rig.home.tabs.append(tab)
            open.status.name = "Fix the login button"
            let toOpen = try await rig.send("login button", "hello")
            #expect(toOpen.ok && toOpen.short == nil && toOpen.message == "Sent.", "\(toOpen)")
            #expect(rig.tabs.count == 2)
        }

        /// Act unlimited only, as `chat.open` then `chat.send`; never above the caller's mode.
        @Test func tiersAndModesAreChatOpensThenChatSends() async throws {
            let rig = try Rig([Self.login, Self.thread])
            defer { rig.finish() }
            AgentGrants.set(.own, chat: rig.caller.id.uuidString)
            let own = try await rig.send("login page", "hello")
            #expect(!own.ok && own.code == "tier")
            #expect(rig.tabs.count == 1 && WakeBackend.made.isEmpty)
            AgentGrants.set(.drive, chat: rig.caller.id.uuidString)
            // A caller in Plan: a Codex chat's lowest mode does more, so it isn't opened at all…
            rig.caller.setMode("plan", remember: false)
            let codex = try await rig.send("Refunds plan", "hello")
            #expect(!codex.ok && codex.message.hasPrefix("Only you can open a Codex chat from this one"), "\(codex)")
            #expect(rig.tabs.count == 1)
            // …and a Claude chat opens in Plan, no freer than the caller.
            let claude = try await rig.send("login page", "hello")
            #expect(claude.ok, "\(claude)")
            let woken = try #require(rig.tabs.last)
            #expect(woken.controls.mode == "plan" && woken.noFreer(than: rig.caller))
            // A "!" line or a "/" command never wakes anything.
            for text in ["!rm -rf x", "/login", "/review"] {
                let refused = try await rig.send("Refunds plan", text)
                #expect(!refused.ok && refused.code == "refused", "\(text): \(refused)")
            }
            #expect(rig.tabs.count == 2)
        }

        /// `folder` scopes the lookup: the caller's own folder's History wakes; another folder's
        /// past chat would open with its Arsenal off, out of the caller's reach, so it isn't opened.
        @Test func folderScopesTheLookup() async throws {
            let deploy = SessionSummary(id: "d3a1b2c3-1111-4222-8333-000000000004", agent: .claude, title: "Deploy", updated: Date(timeIntervalSince1970: 1_787_000_000))
            let rig = try Rig([Self.login])
            defer { rig.finish() }
            let other = try rig.other("ops", [deploy])
            // Not in this window's History.
            let here = try await rig.send("Deploy", "ship it")
            #expect(!here.ok && here.code == "no_chat")
            // Named in its folder: found, and refused before anything opens.
            let there = try await rig.send("Deploy", "ship it", folder: other.folder.path)
            #expect(!there.ok && there.code == "not_own" && there.message.hasPrefix("“Deploy” is in History in "), "\(there)")
            #expect(other.tabs.compactMap(\.chat).isEmpty && rig.tabs.count == 1)
            // The caller's own folder, named: as without it.
            let own = try await rig.send("login page", "hello", folder: rig.home.folder.path)
            #expect(own.ok && own.message == "Opened “Fix the login page”. Sent.", "\(own)")
            // A folder no window has: as kore history says it.
            let none = try await rig.send("login page", "hello", folder: "/nowhere/at/all")
            #expect(!none.ok && none.code == "no_window")
        }

        @Test func pastChatRefs() {
            let rows: [(id: String, title: String, archived: Bool)] = [
                ("5e55f00d-1111", "Fix the login page", false), ("5e55aaaa-2222", "Fix the login button", false),
                ("7a8b9c0d-3333", "Refunds", false), ("9f9f9f9f-4444", "Old refunds", true), ("abcdef12-5555", "fix the login", false),
            ]
            // Its whole id, or the start of it (6 or more) only one has.
            #expect(AgentRefs.resolvePast("5E55F00D-1111", sessions: rows) == .session("5e55f00d-1111"))
            #expect(AgentRefs.resolvePast("5e55f0", sessions: rows) == .session("5e55f00d-1111"))
            #expect(AgentRefs.resolvePast("5e55", sessions: rows) == .none)
            #expect(AgentRefs.resolvePast("9f9f9f", sessions: rows) == .session("9f9f9f9f-4444"))
            // A title equal to it wins over ones that hold it; a part only one has.
            #expect(AgentRefs.resolvePast("Fix the login", sessions: rows) == .session("abcdef12-5555"))
            #expect(AgentRefs.resolvePast("button", sessions: rows) == .session("5e55aaaa-2222"))
            // Several: each, to choose from.
            #expect(AgentRefs.resolvePast("login", sessions: rows) == .ambiguous(["5e55f00d-1111", "5e55aaaa-2222", "abcdef12-5555"]))
            // Archived only by id; nothing, ".", or no match: none.
            #expect(AgentRefs.resolvePast("refunds", sessions: rows) == .session("7a8b9c0d-3333"))
            #expect(AgentRefs.resolvePast("Old refunds", sessions: rows) == .none)
            #expect(AgentRefs.resolvePast("", sessions: rows) == .none)
            #expect(AgentRefs.resolvePast(".", sessions: rows) == .none)
            #expect(AgentRefs.resolvePast("deploy", sessions: rows) == .none)
        }
    }
}
