import Foundation
import KoreCore
import KoreUI

/// Several logins for one CLI (Account popup): signed in, the row's sign-in reads Add account,
/// and its palette lists only the methods that make a login of their own. Finished as someone
/// new, the login is kept, listed under main with a ✓, and the chat's CLI starts again in its
/// folder; the list takes the header's place, the active login first in weight with its plan
/// and method, main's caption "Main". A row switches to its login without a sign-in, and the
/// chat moves again; another login's ⋯ signs that login in again where it is, switching nothing.
final class AccountLogins: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let accounts = ScriptedAccounts.shared
        let work = codex ? ScriptedAccounts.codex(email: "work@acme.dev", plan: "business") : ScriptedAccounts.claude(
            email: "work@acme.dev", org: "Acme Labs", plan: "team")
        let me = codex ? ScriptedAccounts.codex() : ScriptedAccounts.claude()
        let logins = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { $0.app.chat?.storyLogins == want }
        }
        let relaunches = { (story: StoryContext) in try story.scriptedBackend().log.filter { $0 == .relaunch }.count }
        let added = { (part: StoryID.Part) in Self.added(provider, part) }
        return [
            UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            logins("main alone, the account in the header", ["✓ you@example.com"]),
            ExpectElement(.id(StoryID.Composer.accountLogin("main")), .absent),
            // Add account: its palette, then a sign-in in a folder of its own, kept as someone new.
            Press(part(.switch)),
            Expect("only the methods that make a login", found: { $0.app.chat?.storyAccountMenu?.joined(separator: " | ") }) {
                $0.app.chat?.storyAccountMenu == Self.addMenu(codex)
            },
            Expect("no sign-in yet") { _ in !accounts.isWaiting(provider) },
            FadesEnd(),
            Snapshot("account-add-palette"),
            Press(.id(StoryID.Composer.accountMethod(Self.addMenu(codex)[0]))),
            Expect("a sign-in waits for the browser") { _ in accounts.isWaiting(provider) },
            Expect("the browser finishes as work@acme.dev") { _ in
                accounts.finish(provider, as: work)
                return true
            },
            logins("the new login kept and active", ["you@example.com", "✓ work@acme.dev"]),
            WaitForElement(.id(StoryID.Composer.accountLogin("main"))),
            Expect("the chat's CLI started again", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 1 },
            Expect("the active login's folder goes to the CLI") { _ in
                CLIProfiles.overrides(provider).values.first?.hasPrefix(CLIProfiles.root.value?.path ?? "-") == true
            },
            Expect("the active login's account read") { _ in
                if case .signedIn = AccountStore.shared.status(provider) { return true }
                return false
            },
            Snapshot("account-logins"),
            // Switch to main: no sign-in, the chat moves back.
            Expect("main's status, as its folder reads") { _ in
                accounts.finish(provider, as: me)
                return true
            },
            Press(.id(StoryID.Composer.accountLogin("main"))),
            logins("main active again", ["✓ you@example.com", "work@acme.dev"]),
            Expect("no sign-in") { _ in !accounts.isWaiting(provider) },
            Expect("the chat's CLI started again", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 2 },
            Expect("each time at once, its models reloaded before a send", found: { (try? $0.scriptedBackend().log.filter { $0 == .restarted }.count).map { "\($0) restarts" } }) {
                try $0.scriptedBackend().log.filter { $0 == .restarted }.count == 2
            },
            Expect("main's folder: nothing added to the CLI's") { _ in CLIProfiles.overrides(provider).isEmpty },
            Expect("the active login's account read") { _ in
                if case .signedIn = AccountStore.shared.status(provider) { return true }
                return false
            },
            Snapshot("account-logins-main"),
            // At rest: Add account (its palette of methods) and Sign out under the list.
            Key(.escape),
            ExpectElement(popup, .absent),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            ExpectElement(part(.switch)),
            ExpectElement(part(.signOut)),
            FadesEnd(),
            Snapshot("account-logins-rest"),
            // Another login's ⋯ signs it in again in its own folder: its row changes, nothing switches.
            Press(added(.hover)),
            Press(added(.method)),
            Press(.id(StoryID.Composer.accountMethod(Self.addMenu(codex)[0]))),
            Expect("its browser finishes as work2@acme.dev") { _ in
                guard accounts.isWaiting(provider) else { return false }
                accounts.finish(provider, as: codex ? ScriptedAccounts.codex(email: "work2@acme.dev", plan: "business")
                    : ScriptedAccounts.claude(email: "work2@acme.dev", org: "Acme Labs", plan: "team"))
                return true
            },
            logins("its row is the new account, main still active", ["✓ you@example.com", "work2@acme.dev"]),
            Expect("no switch", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 2 },
        ]
    }

    /// The added login's row, or a part of it.
    static func added(_ provider: String, _ part: StoryID.Part? = nil) -> Locator {
        Locator("the added login's row") { _ in
            guard let id = CLIProfiles.added(provider).first?.id else { return .failure(LocatorMiss("no added login", pending: true)) }
            let row = StoryID.Composer.accountLogin(id)
            return .success(part.map { row.part($0) } ?? row)
        }
    }

    /// Add account's palette: each CLI's methods that sign a login's own folder in.
    static func addMenu(_ codex: Bool) -> [String] {
        codex
            ? ["Sign in with ChatGPT", "Sign in with Device Code", "Provide your own API key…"]
            : [
                "Claude account with subscription", "Claude account with SSO",
                "Anthropic Console account/Sign in with your Console account (recommended)", "Anthropic Console account/Create an API key (legacy)",
            ]
    }
}

/// A switch of login stops every working chat of the CLI: with a turn running, a background
/// agent and a background command, a login row's caption under the pointer says "Stops 1
/// working chat."; picked, the turn is interrupted, the agent and the command stopped, and the
/// chat's CLI starts again as the new login once they have.
class AccountSwitchStops: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    class var scheduledOnly: Bool { false }
    class var deaf: Bool { false }
    class var checkQueue: Bool { false }
    class var observed: Bool { false }

    class func script(_ provider: String) -> CLIScript {
        let base = AccountPopup.script(provider)
        let command = ActiveCommand(
            id: "dev", kind: scheduledOnly ? .scheduled : .shell, title: "Run the dev server", command: "npm run dev", folder: "/tmp", startedAt: Date(), owner: .main,
            toolId: "call-dev", output: .stream)
        // A turn that starts an agent and a command, then works until a Stop.
        let work: [Beat] = [
            .startTurn, AgentMapStories.spawn("scout", "Scout the repo", background: true), .event(.commandStarted(command)),
            .wait(.release),
        ] + Beat.answer("Done.") + [.finishTurn(.completed)]
        let beats: [Beat] = scheduledOnly ? [.startTurn, .event(.commandStarted(command)), .finishTurn(.completed)] : work
        var script = CLIScript(start: base.start, turns: [beats])
        script.deaf = deaf
        script.observedAgents = observed ? ["scout"] : []
        return script
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let accounts = ScriptedAccounts.shared
        let work = codex ? ScriptedAccounts.codex(email: "work@acme.dev", plan: "business") : ScriptedAccounts.claude(
            email: "work@acme.dev", org: "Acme Labs", plan: "team")
        let me = codex ? ScriptedAccounts.codex() : ScriptedAccounts.claude()
        let logins = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { $0.app.chat?.storyLogins == want }
        }
        let log = { (story: StoryContext) in try story.scriptedBackend().log }
        let relaunches = { (story: StoryContext) in try log(story).filter { $0 == .relaunch }.count }
        let open: [any Step] = [Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup)]
        let main = StoryID.Composer.accountLogin("main")
        return [UseScript(Self.script(provider), for: provider), SeedLogins(provider: provider), OpenFolder(), StartChat()]
            + [WaitForFocus(.id(StoryID.Composer.field))] + open + [
                Press(part(.switch)),
                Press(.id(StoryID.Composer.accountMethod(AccountLogins.addMenu(codex)[0]))),
                Expect("the browser finishes as work@acme.dev") { _ in
                    guard accounts.isWaiting(provider) else { return false }
                    accounts.finish(provider, as: work)
                    return true
                },
                logins("the new login active", ["you@example.com", "✓ work@acme.dev"]),
                Expect("nothing working: no caption on a switch") { $0.app.chat?.storyLoginSwitchCaption == nil },
                Key(.escape),
                ExpectElement(popup, .absent),
                // At work: a turn, a background agent and a background command.
                Send("Work on it"),
                Expect("a turn, an agent and a command running") { story in
                    let chat = try story.activeChat()
                    return (Self.scheduledOnly ? !chat.isRunning && chat.storyRunningAgents == 0 : chat.isRunning && chat.storyRunningAgents == 1)
                        && chat.storyLiveCommands == 1
                },
            ] + (Self.checkQueue ? [Queue("first queued") as any Step, Queue("second queued")] : []) + open + [
                WaitForElement(.id(main)),
                Press(.id(main.part(.hover))),
                Expect("under the pointer, what a switch stops", found: { $0.app.chat?.storyLoginSwitchCaption }) {
                    $0.app.chat?.storyLoginSwitchCaption == "Stops 1 working chat."
                },
                FadesEnd(),
                Snapshot("account-switch-stops"),
                Expect("main's status, as its folder reads") { _ in
                    accounts.status[provider] = me
                    return true
                },
                Press(.id(main)),
                logins("main active", ["✓ you@example.com", "work@acme.dev"]),
                Expect("the turn interrupted, the agent and the command stopped", found: { try? "\(log($0))" }) { story in
                    let log = try log(story)
                    if Self.scheduledOnly { return !log.contains(.stopCommand("dev")) }
                    return log.contains(.interrupt) && log.contains(.stopAgent("scout")) == !Self.observed && log.contains(.stopCommand("dev"))
                },
                Expect("owned work stopped, observed work preserved") { story in
                    let chat = try story.activeChat()
                    if Self.observed { return !chat.isRunning && chat.storyRunningAgents == 1 && chat.storyLiveCommands == 0 }
                    return !chat.storyHasWork
                },
                Expect("unaccepted queued text preserved") { story in
                    if !Self.checkQueue { return true }
                    return try story.activeChat().draft == "first queued\nsecond queued"
                },
                Expect("the CLI started again as the new login", found: { try? "\(relaunches($0)) relaunches" }) { try relaunches($0) == 2 },
            ]
    }
}

/// The login list's edge cases. Signed out outside Kore, the list stays (the active row "Signed
/// out", the row under it the signed-out one) and another login is still a click away. Signed in
/// as an account another login already is (same email, same organisation), that login reads
/// "Duplicate", quietly, and its ⋯ offers Remove duplicate under its methods.
final class AccountLoginEdges: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let product = codex ? "Codex" : "Claude Code"
        let popup = Locator.id(StoryID.Composer.account)
        let part = { (part: StoryID.Part) in Locator.id(StoryID.Composer.account.part(part)) }
        let accounts = ScriptedAccounts.shared
        let work = codex ? ScriptedAccounts.codex(email: "work@acme.dev", plan: "business") : ScriptedAccounts.claude(
            email: "work@acme.dev", org: "Acme Labs", plan: "team")
        let me = codex ? ScriptedAccounts.codex() : ScriptedAccounts.claude()
        let out: JSONValue = codex ? ["account": nil, "requiresOpenaiAuth": true] : ["loggedIn": false, "authMethod": "none"]
        let logins = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyLogins.joined(separator: " | ") }) { $0.app.chat?.storyLogins == want }
        }
        let open: [any Step] = [Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup)]
        let main = StoryID.Composer.accountLogin("main")
        let added = { (part: StoryID.Part?) in AccountLogins.added(provider, part) }
        let status = { (what: String, _ reply: JSONValue) in
            Expect(what) { _ in
                accounts.status[provider] = reply
                return true
            }
        }
        return [UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider), OpenFolder(), StartChat()]
            + [WaitForFocus(.id(StoryID.Composer.field))] + open + [
                Press(part(.switch)),
                Press(.id(StoryID.Composer.accountMethod(AccountLogins.addMenu(codex)[0]))),
                Expect("the browser finishes as work@acme.dev") { _ in
                    guard accounts.isWaiting(provider) else { return false }
                    accounts.finish(provider, as: work)
                    return true
                },
                logins("the new login active", ["you@example.com", "✓ work@acme.dev"]),
                status("main's status, as its folder reads", me),
                Press(.id(main)),
                logins("main active", ["✓ you@example.com", "work@acme.dev"]),
                // Signed out from a terminal: the list stays, with the signed-out row under it.
                status("main signed out outside Kore", out),
                Key(.escape),
                ExpectElement(popup, .absent),
            ] + open + [
                logins("the list kept, main signed out", ["✓ you@example.com · Signed out", "work@acme.dev"]),
                Expect("the signed-out row", found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) {
                    $0.app.chat?.storyAccount == ["\(product) isn't signed in."]
                },
                ExpectElement(part(.signIn)),
                FadesEnd(),
                Snapshot("account-logins-signed-out"),
                // The other login is a click away.
                status("work's status, as its folder reads", work),
                Press(added(nil)),
                logins("switched to work", ["you@example.com · Signed out", "✓ work@acme.dev"]),
                // Main signs in again as work: the added login is the same account.
                status("main's status, as its folder reads", out),
                Press(.id(main)),
                logins("main active, signed out", ["✓ you@example.com · Signed out", "work@acme.dev"]),
                Press(part(.signIn)),
                Expect("the browser finishes as work@acme.dev") { _ in
                    guard accounts.isWaiting(provider) else { return false }
                    accounts.finish(provider, as: work)
                    return true
                },
                logins("the added login flagged", ["✓ work@acme.dev", "work@acme.dev · Duplicate"]),
                FadesEnd(),
                Snapshot("account-logins-duplicate"),
                Press(added(.hover)),
                Press(added(.method)),
                Expect("its methods, then Remove duplicate", found: { $0.app.chat?.storyAccountMenu?.joined(separator: " | ") }) {
                    $0.app.chat?.storyAccountMenu == AccountLogins.addMenu(codex) + ["Remove duplicate"]
                },
                FadesEnd(),
                Snapshot("account-login-menu"),
                Press(.id(StoryID.Composer.accountMethod("Remove duplicate"))),
                logins("the duplicate gone", ["✓ work@acme.dev"]),
                Expect("signed out of its own folder only") { _ in accounts.log.contains(.signOut(provider)) },
            ]
    }
}

/// Waits out the row's fade, so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}

/// The logins' folder and the CLI's main one, in the run's scratch.
private struct SeedLogins: Step {
    let provider: String
    var label: String { "Give the logins a folder of their own" }

    func run(_ story: StoryContext) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kore-logins-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let main = base.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent(provider == "codex" ? "sessions" : "projects"), withIntermediateDirectories: true)
        CLIProfiles.root.value = base.appendingPathComponent("accounts", isDirectory: true)
        CLIProfiles.mains.value = [provider: main]
        CLIProfiles.reload()
    }
}

/// Inactive and never-used logins read their own plan totals. A mismatched account cannot
/// borrow another row's bars, and closing/reopening the card reuses the minute's cache.
final class AccountUsageMeters: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant == .codex ? "codex" : "claude"
        let popup = Locator.id(StoryID.Composer.account)
        return [
            UseScript(AccountPopup.script(provider), for: provider), SeedLogins(provider: provider),
            Do("Add two isolated login fixtures") { _ in
                let unused = try CLIProfiles.prepare(provider)
                CLIProfiles.adopt(provider, unused, email: "unused@example.com", workspace: provider == "codex" ? "ChatGPT Pro Lite" : "Unused Org")
                let mismatch = try CLIProfiles.prepare(provider)
                CLIProfiles.adopt(provider, mismatch, email: "missing@example.com", workspace: provider == "codex" ? "ChatGPT Pro Lite" : "Missing Org")
                CLIProfiles.activate(provider, nil)
                StorylineSeams.loginUsage = { cli, id in
                    let login = CLIProfiles.added(cli).first { $0.id == id }
                    let email = id == nil ? "you@example.com" : login?.email == "unused@example.com" ? "unused@example.com" : "another@example.com"
                    let org = id == nil ? "you@example.com's Organization" : login?.workspace
                    let unused = email == "unused@example.com"
                    return PlanReading(account: .init(plan: cli == "codex" ? "ChatGPT Pro Lite" : nil, email: email,
                        organization: cli == "claude" ? org : nil, access: .plan), limits: .init(bars: [
                        PlanLimit(title: "Session (5hr)", used: unused ? 0 : 52, resetsAt: unused ? nil : Date().addingTimeInterval(2 * 3600)),
                        PlanLimit(title: "Weekly (7 day)", used: unused ? 0 : 18, resetsAt: unused ? nil : Date().addingTimeInterval(3 * 86400)),
                    ]))
                }
            },
            OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            Expect("main and unused login show separate totals; a mismatch shows unavailable", found: { $0.app.chat?.storyLoginUsage.description }) { story in
                guard let lines = story.app.chat?.storyLoginUsage,
                    let unused = CLIProfiles.added(provider).first(where: { $0.email == "unused@example.com" }),
                    let mismatch = CLIProfiles.added(provider).first(where: { $0.email == "missing@example.com" })
                else { return false }
                return lines["main"] == ["Session · 52%", "Weekly · 18%"]
                    && lines[unused.id] == ["Session · 0%", "Weekly · 0%"]
                    && lines[mismatch.id] == ["Usage unavailable"]
            },
            Expect("each login shows its supplied reset times; missing times stay absent") { story in
                guard let resets = story.app.chat?.storyLoginResets,
                    let unused = CLIProfiles.added(provider).first(where: { $0.email == "unused@example.com" }),
                    let mismatch = CLIProfiles.added(provider).first(where: { $0.email == "missing@example.com" })
                else { return false }
                return resets["main"] == ["Resets in 2h", "Resets in 3d"]
                    && resets[unused.id] == [] && resets[mismatch.id] == []
            },
            FadesEnd(), Snapshot("account-usage-meters"),
            Key(.escape), ExpectElement(popup, .absent),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            Expect("reopening keeps each login's own bars", found: { $0.app.chat?.storyLoginUsage.description }) { story in
                let values = story.app.chat?.storyLoginUsage.values ?? Dictionary<String, [String]>().values
                return values.contains(["Session · 52%", "Weekly · 18%"])
                    && values.contains(["Session · 0%", "Weekly · 0%"])
                    && values.contains(["Usage unavailable"])
            },
        ]
    }
}

/// Armed jobs cannot acknowledge Stop; switching still closes their old CLI.
final class AccountSwitchStopsScheduled: AccountSwitchStops {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var scheduledOnly: Bool { true }
}

/// Missing all Stop acknowledgements cannot leave any old-account work behind.
final class AccountSwitchStopsDeaf: AccountSwitchStops {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var deaf: Bool { true }
    override class var checkQueue: Bool { true }
}

/// Watching another client's agent never authorizes stopping that process on a login switch.
final class AccountSwitchPreservesObserved: AccountSwitchStops {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var observed: Bool { true }
}

/// A sign-in landing on a new identity must force cleanup just as picking a saved login does.
final class AccountSignInStopsDeaf: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant == .codex ? "codex" : "claude"
        var script = AccountSwitchStops.script(provider)
        script.deaf = true
        let account = StoryID.Composer.account
        let reply = variant == .codex ? ScriptedAccounts.codex(email: "changed@example.com")
            : ScriptedAccounts.claude(email: "changed@example.com")
        return [UseScript(script, for: provider), OpenFolder(), StartChat(), Send("Work on it"),
            Expect("all owned work running") { story in
                let chat = try story.activeChat()
                return chat.isRunning && chat.storyRunningAgents == 1 && chat.storyLiveCommands == 1
            },
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))),
            WaitForElement(.id(account)), Press(.id(account.part(.switch))),
            Expect("the new sign-in lands") { _ in
                guard ScriptedAccounts.shared.isWaiting(provider) else { return false }
                ScriptedAccounts.shared.finish(provider, as: reply)
                return true
            },
            Expect("deaf work ended and the new account started") { story in
                let chat = try story.activeChat()
                let log = try story.scriptedBackend().log
                return !chat.storyHasWork && log.filter { $0 == .relaunch }.count == 1
            },
        ]
    }
}
