import AppKit
import Foundation
import KoreCore
import KoreUI

// The README's pictures: each one tells a feature with the scripted CLI in a demo folder, so no
// real account, email or chat shows. `scripts/storylines.sh --tag readme` takes them all; the
// folder each opens is its name.

/// Several logins for Claude in Account, privacy on: main active with its limits, a work login
/// and a second one a click away.
final class ReadmeAccounts: Storyline {
    override class var storyName: String { "acme-web" }
    override class var tags: Set<Tag> { ["readme"] }
    override class var needs: Needs { Needs(window: CGSize(width: 1000, height: 600)) }

    override func steps() -> [any Step] {
        let popup = Locator.id(StoryID.Composer.account)
        return [
            UseScript(Readme.script(model: "default", reply: Readme.loginReply), for: "claude"),
            Do("Three logins: main, work and a side project; each reads its own limits") { story in
                Readme.privateEmails(story)
                let base = FileManager.default.temporaryDirectory.appendingPathComponent("kore-logins-\(UUID().uuidString.prefix(8))", isDirectory: true)
                let main = base.appendingPathComponent("main", isDirectory: true)
                try FileManager.default.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
                CLIProfiles.root.value = base.appendingPathComponent("accounts", isDirectory: true)
                CLIProfiles.mains.value = ["claude": main]
                CLIProfiles.reload()
                for (email, org) in [("dev@acme.dev", "Acme Labs"), ("side@example.com", "Side project")] {
                    CLIProfiles.adopt("claude", try CLIProfiles.prepare("claude"), email: email, workspace: org)
                }
                CLIProfiles.activate("claude", nil)
                StorylineSeams.loginUsage = { cli, id in
                    let login = CLIProfiles.added(cli).first { $0.id == id }
                    let used: (Double, Double) = id == nil ? (64, 31) : (12, 47)
                    return PlanReading(account: .init(plan: nil, email: login?.email ?? "you@example.com",
                        organization: login?.workspace ?? "you@example.com's Organization", access: .plan), limits: .init(bars: [
                        PlanLimit(title: "Session (5hr)", used: used.0, resetsAt: Date().addingTimeInterval(2 * 3600 + 900)),
                        PlanLimit(title: "Weekly (7 day)", used: used.1, resetsAt: Date().addingTimeInterval(3 * 86400)),
                    ]))
                }
            },
            OpenFolder(), StartChat("claude"),
            Send("Add rate limiting to the login endpoint"), TurnFinished(1),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
            Readme.Settle(), Snapshot("accounts"),
        ]
    }
}

/// One chat at work in the ways that keep it going: a compaction it made on its own, then Plan
/// with commands allowed, Stay awake on, and a pasted screenshot in the next message.
final class ReadmeFlow: Storyline {
    override class var storyName: String { "acme-api" }
    override class var tags: Set<Tag> { ["readme"] }
    override class var needs: Needs { Needs(window: CGSize(width: 1000, height: 720)) }

    override func steps() -> [any Step] {
        let turn: [Beat] = [.startTurn] + Beat.answer("Reproducing it first: totals over $1,000 come out a cent short.") + [
            .tool(name: "Bash", detail: "npm test -- checkout", output: "✗ applies tax after rounding (1 failed, 41 passed)"),
            .context(used: 182_000),
            .event(.compactionStarted(auto: true)), .event(.compacted(at: Date(), auto: true)),
            .event(.compactionSummary("Checkout totals over $1,000 are a cent short: tax is applied after rounding.")),
            .fileEdit(path: "src/checkout/total.ts", content: Readme.fix),
            .tool(name: "Bash", detail: "npm test -- checkout", output: "✓ 42 passed"),
        ] + Beat.answer("Fixed: tax is now applied before rounding, in `total.ts`. All 42 checkout tests pass.") + [
            .context(used: 46_000), .finishTurn(.completed),
        ]
        return [
            UseScript(CLIScript(start: [Readme.controls("default")], turns: [turn]), for: "claude"),
            Do("Stay awake from off") { story in
                StoryAwake.reset()
                _ = story.stash(Readme.AwakeOff.self) { Readme.AwakeOff() }
            },
            OpenFolder(), StartChat("claude"),
            Send("Checkout totals are off for carts over $1,000. Find out why and fix it."), TurnFinished(1),
            Press(.id(StoryID.Composer.mode)), WaitForElement(.id(StoryID.Composer.modes)),
            Press(.id(StoryID.Composer.modeRow("plan"))),
            WaitForElement(.id(StoryID.Composer.planAllow)), Press(.id(StoryID.Composer.planAllow)),
            Expect("commands allowed while planning") { $0.app.chat?.storyPlanAllow == "on" },
            Press(.id(StoryID.Titlebar.awakeMode("always"))),
            Expect("awake until turned off") { _ in StoryAwake.state == "holding" },
            Do("Paste a screenshot") { story in
                guard let window = story.window, let png = snapshot(window) else { throw StoryFailure.other("no window to picture") }
                let file = story.folder.appendingPathComponent("refund-total.png")
                try png.write(to: file)
                try story.activeChat().storyAttach([file])
            },
            WaitForFocus(.id(StoryID.Composer.field)),
            TypeText("Plan the same fix for refunds, they show the bug in this screenshot"),
            Readme.Settle(), Snapshot("flow"),
        ]
    }
}

/// A Claude chat carried on in Codex: its turn, the divider, then Codex's own turn.
final class ReadmePort: Storyline {
    override class var storyName: String { "acme-mobile" }
    override class var tags: Set<Tag> { ["readme"] }
    override class var needs: Needs { Needs(window: CGSize(width: 1000, height: 640)) }

    override func steps() -> [any Step] {
        let reply = [.startTurn] + Beat.answer("Reading the API's new check first.") + [
            .tool(name: "Bash", detail: "rg -n \"minimumVersion\" ios/", output: "ios/App/Session.swift:18: let minimumVersion = \"2.3\""),
            .fileEdit(path: "ios/App/Session.swift", content: Readme.iosFix),
        ] + Beat.answer("Done: the app now reads `X-Min-Version` and asks to update when it's newer.") + [.finishTurn(.completed)]
        return [
            UseScript(CLIScript(start: [Readme.controls("gpt-6", name: "GPT-6")], turns: [reply]), for: "codex"),
            OpenFolder(), StartChat("codex"),
            ImportHistory("api-version-check.jsonl", lines: Readme.claudeChat),
            Send("Now add the same check to the iOS client"),
            Expect.rows("Codex's answer under the divider") { $0.last { $0.kind == "assistant" }?.text.hasPrefix("Done: the app") == true },
            // The new turn's rows take a moment longer to lay out under the carried part.
            Readme.Settle(for: .seconds(2)), Snapshot("port"),
        ]
    }
}

/// A board as a control panel: four chats of one release, Claude and Codex side by side,
/// in one tab.
final class ReadmeBoard: Storyline {
    override class var storyName: String { "acme-platform" }
    override class var tags: Set<Tag> { ["readme"] }
    override class var needs: Needs { Needs(window: CGSize(width: 1280, height: 780)) }

    override func steps() -> [any Step] {
        let chats: [(provider: String, ask: String, answer: String)] = [
            ("claude", "Migrate the orders table to UUID keys", "Migration written and tested on a copy: 2.1M rows in 48 s, no downtime."),
            ("codex", "Why is the nightly build slow?", "The image cache is cold: it rebuilds `node_modules` each night. Cached it, the build is down from 19 to 6 minutes."),
            ("claude", "Review PR #412", "Two things: the retry has no cap, and the new env var isn't in `.env.example`. The rest looks good."),
            ("codex", "Draft the 2.4 release notes", "Drafted in `CHANGELOG.md`: UUID order keys, faster nightly builds, and the refund total fix."),
        ]
        return [OpenFolder()] + chats.flatMap { chat -> [any Step] in
            [
                UseScript(CLIScript(start: [Readme.controls(chat.provider == "codex" ? "gpt-6" : "default", name: chat.provider == "codex" ? "GPT-6" : "Default")],
                    turns: [CLIScript.reply(chat.answer)]), for: chat.provider),
                StartChat(chat.provider), Send(chat.ask), TurnFinished(1),
            ]
        } + [
            MakeBoard(name: "Release 2.4", take: chats.count),
            Readme.Settle(), Snapshot("board"),
        ]
    }
}

/// What the README's storylines share.
@MainActor
enum Readme {
    /// Controls with one model, as a CLI would list it.
    static func controls(_ model: String, name: String = "Default") -> Beat {
        .event(.controlsLoaded(ChatControls(
            models: [ModelOption(id: model, name: name, resolved: model, efforts: ["low", "medium", "high"])],
            model: model, effort: "high", commands: [])))
    }

    static func script(model: String, reply: String) -> CLIScript {
        CLIScript(start: [controls(model)], turns: [CLIScript.reply(reply)])
    }

    static let loginReply = "Added a sliding-window limit of 10 attempts a minute per IP, with a test for the 11th."

    /// Privacy on for the picture, and back as it was after.
    static func privateEmails(_ story: StoryContext) {
        _ = story.stash(PrivacyWas.self) { PrivacyWas(Chat.storyAccountPrivacy) }
        Chat.storyAccountPrivacy = true
    }

    final class PrivacyWas: StoryFinishing {
        let on: Bool
        init(_ on: Bool) { self.on = on }
        func finish() { Chat.storyAccountPrivacy = on }
    }

    final class AwakeOff: StoryFinishing {
        func finish() { StoryAwake.reset() }
    }

    /// Lets fades and the caret settle, so the picture shows where they end.
    struct Settle: Step {
        var wait: Duration = .milliseconds(600)
        var label: String { "Let the window settle" }
        var timeout: Duration? { wait + .seconds(5) }
        init(for wait: Duration = .milliseconds(600)) { self.wait = wait }
        func run(_ story: StoryContext) async throws {
            try await story.idle()
            let end = ContinuousClock.now + wait
            try await story.until("the fades to end") { ContinuousClock.now >= end }
        }
    }

    static let fix = """
        export function total(cart: Cart): number {
          const taxed = cart.subtotal * (1 + cart.taxRate)
          return Math.round(taxed * 100) / 100
        }
        """

    static let iosFix = """
        let minimumVersion = response.value(forHTTPHeaderField: "X-Min-Version") ?? "2.3"
        """

    /// A Claude chat of the API, as its transcript file holds it.
    static var claudeChat: [String] {
        let session = "7c1e-api"
        var lines: [[String: Any]] = []
        var parent: String?
        func add(_ type: String, _ content: Any, _ extra: [String: Any] = [:]) {
            let id = "m\(lines.count)"
            var line: [String: Any] = [
                "parentUuid": parent ?? NSNull(), "isSidechain": false, "type": type, "uuid": id, "sessionId": session,
                "timestamp": "2026-10-24T10:0\(lines.count):00.000Z", "cwd": "/tmp/acme-api",
                "message": type == "user" ? ["role": "user", "content": content] : ["id": id, "role": "assistant", "model": "fixture-model", "content": content],
            ]
            line.merge(extra) { $1 }
            lines.append(line)
            parent = id
        }
        add("user", "Old app versions break on the new auth flow. Make the API reject them cleanly.", ["permissionMode": "default"])
        add("assistant", [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "rg -n \"appVersion\" src/"]]])
        add("user", [["type": "tool_result", "tool_use_id": "t1", "content": "src/auth/session.ts:41: const appVersion = req.header('X-App-Version')"]],
            ["toolUseResult": ["stdout": "src/auth/session.ts:41: const appVersion = req.header('X-App-Version')"]])
        add("assistant", [["type": "text", "text": "Done: requests from apps older than 2.4 now get a 426 with `X-Min-Version: 2.4`, so the app can ask the user to update."]])
        return lines.compactMap { line in
            (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
