import AgentTools
import AppKit
import Foundation
import HostClient
@testable import KoreCore
@testable import LinkProtocol
@testable import src
import Testing

@testable import KoreLink
@testable import KoreUI

/// `kore new --folder` (Act device) and `--silent` on new, open and a send's wake (the owner, for
/// 0.3.7): another folder's window, the open one or one opened for it; the tab in front kept, the
/// window left where it is. Windows open and come forward through `ArsenalWindows`' seams.
extension AgentChannelTests {
    @MainActor
    @Suite("new chats in another folder, and silent ones", .serialized)
    struct NewFolderSilentTests {
        typealias Rig = SendWakeTests.Rig

        /// What the seams were asked: windows opened (place, quiet) and windows brought forward.
        final class Seen {
            var opened: [(FilePlace, Bool)] = []
            var fronted: [Workspace] = []
            var checked: [String] = []
            /// The windows the fake opened, held as the app's open list holds them.
            var made: [Workspace] = []
        }

        /// The rig, its caller at `tier`, and windows opened as a fake: a Mac folder's at once, a
        /// box's never (no box here).
        func rig(_ cli: String, tier: AgentTier = .device, past: [SessionSummary] = []) throws -> (Rig, Seen, () -> Void) {
            let rig = try Rig(past, callerCLI: cli)
            AgentGrants.set(tier, chat: rig.caller.id.uuidString)
            let seen = Seen()
            let saved = (ArsenalWindows.open, ArsenalWindows.front, ArsenalWindows.boxNames, ArsenalWindows.boxReady, ArsenalWindows.patience)
            ArsenalWindows.open = { place, quiet in
                seen.opened.append((place, quiet))
                if case .mac(let path) = place {
                    let workspace = Workspace(folder: URL(fileURLWithPath: path), restore: false)
                    seen.made.append(workspace)
                    rig.show(workspace)
                }
            }
            ArsenalWindows.front = { seen.fronted.append($0) }
            ArsenalWindows.boxNames = { [:] }
            ArsenalWindows.patience = 0
            return (rig, seen, {
                (ArsenalWindows.open, ArsenalWindows.front, ArsenalWindows.boxNames, ArsenalWindows.boxReady, ArsenalWindows.patience) = saved
                rig.finish()
            })
        }

        func call(_ rig: Rig, _ name: String, _ args: [String: Any]) async throws -> (ok: Bool, code: String?, message: String, chat: String?) {
            let channel = try #require(AgentChannel.current)
            let line = await channel.boxCall(chat: rig.caller.id.uuidString, name, args)
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
            let data = object["data"] as? [String: Any] ?? [:]
            return (object["ok"] as? Bool == true, object["code"] as? String, (data["message"] ?? object["message"]) as? String ?? "", data["chat"] as? String)
        }

        /// A window's tabs and the opens seen, for a failure's message.
        static func state(_ window: Workspace, _ seen: Seen?) -> String {
            let tabs = window.tabs.map { $0.chat.map { "\($0.provider.id) \(AgentReads.short($0.id.uuidString))\($0.status.isRunning ? " running" : "") “\($0.title)” in \($0.folder.path)" } ?? "empty" }
            return "tabs \(tabs), opened \(seen.map { "\($0.opened.map(\.0))" } ?? "-")"
        }

        func chat(_ id: String?) -> Chat? { id.flatMap { AgentReads.chatsByID()[$0] } }

        func folder(_ rig: Rig, _ name: String) throws -> URL {
            let url = rig.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // MARK: Tiers

        @Test(arguments: ["claude", "codex"]) func onlyActDeviceOpensAChatInAnotherFolder(cli: String) async throws {
            for tier in [AgentTier.watch, .own, .drive] {
                let (rig, seen, done) = try rig(cli, tier: tier)
                defer { done() }
                let other = try rig.other("b", [])
                let said = try await call(rig, "chat.new", ["folder": other.folder.path])
                #expect(!said.ok && said.code == "tier", "\(tier): \(said)")
                #expect(said.message.hasPrefix("A chat in another folder needs Arsenal's Act device tier; this chat has \(AgentTools.tierName(tier.rawValue))."), "\(said.message)")
                #expect(other.tabs.allSatisfy(\.isEmpty) && seen.opened.isEmpty, "\(tier): \(Self.state(other, seen))")
            }
            for tier in [AgentTier.device, .full] {
                let (rig, _, done) = try rig(cli, tier: tier)
                defer { done() }
                let other = try rig.other("b", [])
                let said = try await call(rig, "chat.new", ["folder": other.folder.path])
                #expect(said.ok && said.message == "Opened a \(rig.caller.provider.name) chat in b.", "\(tier): \(said)")
                #expect(other.tabs.compactMap(\.chat).contains { $0.id.uuidString == said.chat })
            }
        }

        // MARK: Paths

        @Test func thePathMustBeAFolderWithTildeAndLinksResolved() async throws {
            let (rig, seen, done) = try rig("claude")
            defer { done() }
            let missing = try await call(rig, "chat.new", ["folder": rig.root.appendingPathComponent("nope").path])
            #expect(!missing.ok && missing.code == "no_window" && missing.message.hasSuffix("nope isn't there."), "\(missing)")
            let file = rig.root.appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: file)
            let notFolder = try await call(rig, "chat.new", ["folder": file.path])
            #expect(!notFolder.ok && notFolder.message.hasSuffix("notes.txt is a file, not a folder."), "\(notFolder)")
            let empty = try await call(rig, "chat.new", ["folder": " "])
            #expect(!empty.ok && empty.code == "invalid")
            let both = try await call(rig, "chat.new", ["folder": rig.root.path, "place": "mac"])
            #expect(!both.ok && both.message == "Give folder or place, not both.")
            #expect(seen.opened.isEmpty)
            // A link to an open window's folder is that window; a relative path is under the caller's.
            let other = try rig.other("b", [])
            let link = rig.root.appendingPathComponent("b-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other.folder)
            let linked = try await call(rig, "chat.new", ["folder": link.path])
            #expect(linked.ok && other.tabs.compactMap(\.chat).contains { $0.id.uuidString == linked.chat }, "\(linked)")
            let inner = try folder(rig, "app/inner")
            let relative = try await call(rig, "chat.new", ["folder": "inner"])
            #expect(relative.ok, "\(relative)")
            #expect(seen.opened.count == 1 && seen.opened[0].0 == .mac(ArsenalFetch.real(inner.path)))
            // ~ is the home folder, links followed.
            #expect(ArsenalFetch.real("~") == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path)
        }

        // MARK: Windows

        @Test(arguments: ["claude", "codex"]) func anOpenWindowTakesTheTabAndANewOneOpens(cli: String) async throws {
            let (rig, seen, done) = try rig(cli)
            defer { done() }
            let other = try rig.other("b", [])
            let said = try await call(rig, "chat.new", ["folder": other.folder.path, "text": "hello"])
            #expect(said.ok && said.message == "Opened a \(rig.caller.provider.name) chat in b. Sent.", "\(said)")
            let made = try #require(chat(said.chat))
            // In that window, its tab in front, the window brought forward; the caller's untouched.
            #expect(other.activeTab.chat === made && rig.home.activeTab.chat === rig.caller)
            #expect(seen.opened.isEmpty && seen.fronted.count == 1 && seen.fronted[0] === other)
            // No window has c: one opens (not quietly), and the chat is its.
            let c = try folder(rig, "c")
            let fresh = try await call(rig, "chat.new", ["folder": c.path])
            #expect(fresh.ok && fresh.message == "Opened a \(rig.caller.provider.name) chat in c.", "\(fresh)")
            #expect(seen.opened.count == 1 && seen.opened[0].0 == .mac(ArsenalFetch.real(c.path)) && seen.opened[0].1 == false)
            let window = try #require(ArsenalWindows.shown(.mac(ArsenalFetch.real(c.path))))
            #expect(window.activeTab.chat?.id.uuidString == fresh.chat)
            // Opened, it came forward as it opened: not again.
            #expect(seen.fronted.count == 1)
            // A second for c: its window now, none opened.
            let again = try await call(rig, "chat.new", ["folder": c.path])
            #expect(again.ok && seen.opened.count == 1 && window.tabs.count == 2, "\(again) \(Self.state(window, seen))")
        }

        // MARK: The new chat

        @Test(arguments: ["claude", "codex"]) func itStartsWithArsenalOffCappedAndMadeByTheCaller(cli: String) async throws {
            FullAccessReachTests.rememberFullAccess()
            defer { ModeMemory.standIn = nil }
            let (rig, _, done) = try rig(cli)
            defer { done() }
            let (low, remembered) = cli == "claude" ? ("acceptEdits", "auto") : ("askForApproval", "approveForMe")
            rig.caller.setMode(low, remember: false)
            await rig.caller.modeSettled()
            let other = try rig.other("b", [])
            let said = try await call(rig, "chat.new", ["folder": other.folder.path])
            let made = try #require(chat(said.chat), "\(said)")
            #expect(AgentGrants.tier(chat: made.id.uuidString) == .off)
            #expect(made.controls.mode != remembered && made.noFreer(than: rig.caller), "\(made.controls.mode)")
            #expect(made.arsenalStarted(by: rig.caller) && made.arsenalOrigins == Chat.origins(madeBy: rig.caller))
            // A mode above the caller's is refused, as in its own window.
            let higher = try await call(rig, "chat.new", ["folder": other.folder.path, "mode": remembered])
            #expect(!higher.ok && higher.message == "Only you can start a chat above your own mode.", "\(higher)")
        }

        @Test func itCountsTowardTheNewChatLimits() async throws {
            let (rig, _, done) = try rig("claude")
            defer { done() }
            let other = try rig.other("b", [])
            for n in 1...ArsenalRules.madeOpen {
                let said = try await call(rig, "chat.new", ["folder": other.folder.path])
                #expect(said.ok, "\(n): \(said)")
            }
            let over = try await call(rig, "chat.new", ["folder": other.folder.path])
            #expect(!over.ok && over.code == "limit", "\(over)")
        }

        // MARK: Silent

        @Test(arguments: ["claude", "codex"]) func silentKeepsTheTabInFrontAndNothingComesForward(cli: String) async throws {
            let (rig, seen, done) = try rig(cli)
            defer { done() }
            let key = NSApp.keyWindow
            // In the caller's own window: the caller's tab stays in front.
            let own = try await call(rig, "chat.new", ["silent": true])
            #expect(own.ok && rig.home.activeTab.chat === rig.caller, "\(own)")
            #expect(rig.home.tabs.compactMap(\.chat).contains { $0.id.uuidString == own.chat })
            // In another open window, with a tab of its own in front.
            let other = try rig.other("b", [])
            let shown = try #require(other.start(provider: "claude", model: nil, select: true))
            let front = other.activeID
            let said = try await call(rig, "chat.new", ["folder": other.folder.path, "silent": true])
            #expect(said.ok && other.activeID == front && other.activeTab.chat === shown, "\(said)")
            #expect(other.tabs.last?.chat?.id.uuidString == said.chat)
            // A window that has to open opens quietly.
            let c = try folder(rig, "c")
            let fresh = try await call(rig, "chat.new", ["folder": c.path, "silent": true])
            #expect(fresh.ok && seen.opened.count == 1 && seen.opened[0].1 == true, "\(fresh)")
            #expect(seen.fronted.isEmpty && rig.home.activeTab.chat === rig.caller)
            #expect(NSApp.keyWindow === key && other.activeID == front)
        }

        /// Five silent opens in a row: each a few milliseconds of the main thread, the tab in front
        /// never changed, and none of them shown (so none builds its view or starts its CLI).
        @Test(arguments: ["claude", "codex"]) func fiveSilentOpensStayLight(cli: String) async throws {
            let (rig, _, done) = try rig(cli)
            defer { done() }
            let other = try rig.other("b", [])
            _ = other.start(provider: cli, model: nil, select: true)
            let front = other.activeID
            let key = NSApp.keyWindow
            let clock = ContinuousClock()
            var each: [Duration] = []
            for _ in 0..<5 {
                let start = clock.now
                let said = try await call(rig, "chat.new", ["folder": other.folder.path, "silent": true])
                each.append(clock.now - start)
                #expect(said.ok, "\(said)")
                #expect(other.activeID == front && NSApp.keyWindow === key)
            }
            let total = each.reduce(.zero, +)
            print("silent opens (\(cli)): each \(each.map { String(format: "%.2f", Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1e3) }) ms; main thread for five: \(total)")
            // Made, not started: no CLI runs for a tab no one has shown and nothing was sent to.
            let made = other.tabs.dropFirst().compactMap(\.chat)
            #expect(made.count == 5 && made.allSatisfy { !$0.status.isRunning }, "\(Self.state(other, nil))")
            #expect(total < .milliseconds(500), "\(total)")
        }

        @Test func silentOpenAndWakeKeepTheTabInFront() async throws {
            let (rig, seen, done) = try rig("claude", past: [SendWakeTests.login, SendWakeTests.button])
            defer { done() }
            _ = await rig.home.arsenalPast(fresh: true)
            let opened = try await call(rig, "chat.open", ["session": SendWakeTests.login.id, "silent": true])
            #expect(opened.ok && rig.home.activeTab.chat === rig.caller, "\(opened)")
            #expect(rig.tabs.contains { $0.listedId == SendWakeTests.login.id })
            // Open already: it stays where it is.
            let again = try await call(rig, "chat.open", ["session": SendWakeTests.login.id, "silent": true])
            #expect(again.ok && again.message == "It was open." && rig.home.activeTab.chat === rig.caller, "\(again)")
            let woken = try await call(rig, "chat.send", ["chat": "login button", "text": "hi", "silent": true])
            #expect(woken.ok && woken.message.hasPrefix("Opened “Fix the login button”."), "\(woken)")
            #expect(rig.home.activeTab.chat === rig.caller && rig.tabs.contains { $0.listedId == SendWakeTests.button.id })
            #expect(seen.opened.isEmpty && seen.fronted.isEmpty)
        }

        @Test func withoutSilentNothingChanged() async throws {
            let (rig, seen, done) = try rig("claude", tier: .drive, past: [SendWakeTests.login])
            defer { done() }
            let made = try await call(rig, "chat.new", [:])
            #expect(made.ok && made.message == "Opened a Claude chat." && rig.home.activeTab.chat?.id.uuidString == made.chat, "\(made)")
            rig.home.select(rig.home.tabs[0])
            _ = await rig.home.arsenalPast(fresh: true)
            let opened = try await call(rig, "chat.open", ["session": SendWakeTests.login.id])
            #expect(opened.ok && rig.home.activeTab.chat?.listedId == SendWakeTests.login.id, "\(opened)")
            rig.home.select(rig.home.tabs[0])
            let again = try await call(rig, "chat.open", ["session": SendWakeTests.login.id])
            #expect(again.message == "It was open: in front." && rig.home.activeTab.chat?.listedId == SendWakeTests.login.id)
            #expect(seen.opened.isEmpty && seen.fronted.isEmpty)
        }

        // MARK: A box's folder

        @Test func aBoxFolderNeedsABoxKoreHasConnected() async throws {
            let (rig, seen, done) = try rig("claude")
            defer { done() }
            let unknown = try await call(rig, "chat.new", ["folder": "nobox:~/x"])
            #expect(!unknown.ok && unknown.message == "Kore has no box named nobox.", "\(unknown)")
            ArsenalWindows.boxNames = { ["mybox": "mybox"] }
            ArsenalWindows.boxReady = { alias, _ in ArsenalWindows.notConnected(alias) }
            let down = try await call(rig, "chat.new", ["folder": "mybox:~/x"])
            #expect(!down.ok && down.message == ArsenalWindows.notConnected("mybox").message && down.message.hasPrefix("Kore isn't connected to "), "\(down)")
            #expect(seen.opened.isEmpty)
            // Connected, the folder there: its window opens, quietly when asked.
            ArsenalWindows.boxReady = { _, path in
                seen.checked.append(path)
                return nil
            }
            let opening = try await call(rig, "chat.new", ["folder": "mybox:~/x/../y", "silent": true])
            #expect(!opening.ok && opening.message.hasSuffix("isn't ready yet: ask again in a moment."), "\(opening)")
            #expect(seen.checked == ["~/y"] && seen.opened.count == 1 && seen.opened[0].0 == .box(alias: "mybox", path: "~/y") && seen.opened[0].1)
        }
    }
}
