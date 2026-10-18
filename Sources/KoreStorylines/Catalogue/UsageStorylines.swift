import AppKit
import Foundation
import KoreCore
import KoreUI

/// The / menu's Usage: first on a bare "/" (in place of the CLI's own usage command), picked
/// with Return it takes the "/" out and opens the popup where the menu was, with no chip and
/// nothing sent. The popup shows the plan's limits, their titles shortened, with their resets
/// and the extras line. Esc closes it with the composer still focused; reopened from a typed
/// "/lim" mid-text, typing closes it and the key lands in the field; a click outside closes it
/// too, and so does a paste that reaches the draft without a key.
final class UsagePopup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    /// Claude's answers, trimmed from a real `get_usage`, with the extra usage on.
    static var claude: CLIScript {
        let commands = [
            SlashCommand(name: "compact", description: "Summarize the conversation", hint: "", kind: .command),
            SlashCommand(name: "usage", description: "Show plan usage limits", hint: "", kind: .command),
        ]
        let account: JSONValue = [
            "email": "you@example.com", "organization": "Example Org", "subscriptionType": "Claude Max", "apiProvider": "firstParty",
        ]
        let usage: JSONValue = [
            "subscription_type": "max", "rate_limits_available": true,
            "rate_limits": [
                "five_hour": ["utilization": 30.7, "resets_at": .string(iso(hours: 3.2))],
                "seven_day": ["utilization": 44, "resets_at": .string(iso(hours: 6 * 24 + 4))],
                "model_scoped": [["display_name": "Fable", "utilization": 0, "resets_at": .string(iso(hours: 6 * 24 + 4))]],
                "extra_usage": ["is_enabled": true, "monthly_limit": 5000, "used_credits": 1240, "currency": "USD"],
            ],
        ]
        return CLIScript(start: [controls(commands)], usage: .claude(account: account, usage: usage))
    }

    /// Codex's answers, trimmed from a real `account/rateLimits/read`, with a 5h window added.
    static var codex: CLIScript {
        let commands = [
            SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
            SlashCommand(name: "compact", description: "Summarize the thread to free up context", hint: "", kind: .command),
            SlashCommand(name: "pdf", description: "Read and fill PDF files", hint: "", kind: .skill),
        ]
        let account: JSONValue = ["account": ["type": "chatgpt", "email": "you@example.com", "planType": "prolite"]]
        let snapshot: JSONValue = [
            "limitId": "codex",
            "primary": ["usedPercent": 84, "windowDurationMins": 300, "resetsAt": .number(epoch(hours: 2.2))],
            "secondary": ["usedPercent": 6, "windowDurationMins": 10080, "resetsAt": .number(epoch(hours: 4 * 24 + 2))],
            "credits": ["hasCredits": true, "unlimited": false, "balance": "47161.9384695000"],
        ]
        let limits: JSONValue = [
            "rateLimits": snapshot, "rateLimitsByLimitId": ["codex": snapshot],
            "rateLimitResetCredits": ["availableCount": 2, "credits": nil],
        ]
        return CLIScript(start: [controls(commands)], usage: .codex(account: account, rateLimits: limits))
    }

    private static func controls(_ commands: [SlashCommand]) -> Beat {
        .event(.controlsLoaded(ChatControls(
            models: [ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"])], model: "haiku", effort: "low",
            commands: commands)))
    }

    private static func iso(hours: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
    }

    private static func epoch(hours: Double) -> Double { Date().addingTimeInterval(hours * 3600).timeIntervalSince1970.rounded() }

    /// The usage row's top edge is above every other row's.
    @MainActor private static func usageFirst() -> Bool {
        guard let usage = StoryRegistry.entry(StoryID.Composer.command("usage").raw)?.frame,
            let other = StoryRegistry.entry(StoryID.Composer.command("compact").raw)?.frame
        else { return false }
        return usage.minY >= other.maxY - 0.5
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let row = { (name: String) in Locator.id(StoryID.Composer.command(name)) }
        let popup = Locator.id(StoryID.Composer.usage)
        let tab = Locator("the chat's tab") { app in
            app.workspace.map { .success(StoryID.Tabs.tab($0.activeTab.id)) } ?? .failure(LocatorMiss("no workspace"))
        }
        let bars =
            codex
            ? ["5h limit · 84% · Resets in 2h", "Weekly limit · 6% · Resets in 4d"]
            : ["Session (5hr) · 30% · Resets in 3h", "Weekly (7 day) · 44% · Resets in 6d", "Weekly Fable · 0% · Resets in 6d"]
        let titles = bars.compactMap { $0.components(separatedBy: " · ").first }
        let shown = codex ? ["5h", "Weekly"] : ["Session", "Weekly", "Weekly Fable"]
        let header = codex ? "ChatGPT Pro Lite · you@example.com" : "Claude Max · you@example.com · Example Org"
        let composer = { (what: String, draft: String) in
            Expect(what, found: { "chip \($0.app.chat?.command?.name ?? "none"), draft “\($0.app.chat?.draft ?? "?")”" }) { story in
                guard let chat = story.app.chat else { return false }
                return chat.command == nil && chat.draft == draft
            }
        }
        var steps: [any Step] = [
            UseScript(Self.claude, for: "claude"), UseScript(Self.codex, for: "codex"), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            // A bare "/": Usage first, the CLI's own usage command not listed beside it.
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(row("compact")),
            Expect("Usage as the menu's first row") { _ in Self.usageFirst() },
            Snapshot("usage-menu"),
            // Return picks it: the "/" goes, no chip, nothing sent, the popup where the menu was.
            Key(.returnKey),
            WaitForElement(popup),
            ExpectElement(row("compact"), .absent),
            composer("no chip and the “/” gone", ""),
            Expect("the account read once, nothing sent") { story in
                let log = try story.scriptedBackend().log
                return log.filter { $0 == .usage }.count == 1 && !log.contains { if case .send = $0 { true } else { false } }
            },
            Expect("the plan and the account", found: { $0.app.chat?.storyUsageHeader }) { $0.app.chat?.storyUsageHeader == header },
            Expect("the bars with their values and resets", found: { $0.app.chat?.storyUsage.joined(separator: " | ") }) {
                $0.app.chat?.storyUsage == bars
            },
        ]
        steps += titles.map { ExpectElement(.id(StoryID.Composer.usageLimit($0))) }
        steps.append(
            Expect("the rows' titles shortened", found: { $0.app.chat?.storyUsageTitles.joined(separator: " | ") }) {
                $0.app.chat?.storyUsageTitles == shown
            })
        steps += [
            Expect("the extras line", found: { $0.app.chat?.storyUsageExtras }) { story in
                let extras = story.app.chat?.storyUsageExtras ?? ""
                return codex
                    ? extras.hasPrefix("Credits 47") && extras.hasSuffix(" · 2 full resets available")
                    : extras.hasPrefix("Extra usage On · ") && extras.contains("12.40 of ") && extras.hasSuffix(" this month")
            },
            ExpectElement(.id(StoryID.Composer.usage.part(.open))),
            // Esc closes it and goes no further: the composer keeps focus.
            Key(.escape),
            ExpectElement(popup, .absent),
            Expect("the popup closed") { $0.app.chat?.isUsageOpen == false },
            WaitForFocus(.id(StoryID.Composer.field)),
            // Mid-text, "/lim" finds it by "limits"; Tab picks it and leaves the rest of the draft.
            TypeText("fix the bug /lim"),
            WaitForElement(row("usage")),
            Key(.tab),
            WaitForElement(popup),
            composer("the draft as it was before “/lim”", "fix the bug "),
            Expect("the account read again") { try $0.scriptedBackend().log.filter { $0 == .usage }.count == 2 },
            // Reopened, the last reading shows at once, its bars full.
            Snapshot("usage-popup"),
            // Typing closes it, and the key lands in the field.
            TypeText("x"),
            ExpectElement(popup, .absent),
            composer("the typed key in the field", "fix the bug x"),
            WaitForFocus(.id(StoryID.Composer.field)),
            // A click outside closes it, and the click goes on.
            Press(.id(StoryID.Composer.slash)),
            Press(row("usage")),
            WaitForElement(popup),
            Click(tab),
            ExpectElement(popup, .absent),
            // Return closes it and sends nothing: the draft stays.
            Press(.id(StoryID.Composer.slash)),
            Press(row("usage")),
            WaitForElement(popup),
            Key(.returnKey),
            ExpectElement(popup, .absent),
            composer("the draft kept after Return", "fix the bug x "),
            Expect("nothing sent") { story in
                try !story.scriptedBackend().log.contains { if case .send = $0 { true } else { false } }
            },
            // A paste closes it as typing does, though no key reaches the popup.
            Press(.id(StoryID.Composer.slash)),
            Press(row("usage")),
            WaitForElement(popup),
            WaitForFocus(.id(StoryID.Composer.field)),
            PasteText("pasted"),
            ExpectElement(popup, .absent),
            composer("the paste in the field", "fix the bug x pasted"),
        ]
        if codex {
            // A "$" lists skills alone.
            steps += [
                TypeText(" $"),
                WaitForElement(row("pdf")),
                ExpectElement(row("usage"), .absent),
            ]
        }
        return steps
    }
}
