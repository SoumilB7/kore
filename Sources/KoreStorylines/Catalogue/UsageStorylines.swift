import AppKit
import Foundation
import KoreCore
import KoreUI

/// The / menu's Usage: first on a bare "/" (in place of the CLI's own usage command), picked
/// with Return it takes the "/" out and opens the popup where the menu was, with no chip and
/// nothing sent. The popup shows the plan's limits, their titles shortened, with their resets
/// and the extras line. Esc closes it with the composer still focused; reopened from a typed
/// "/lim" mid-text, typing closes it and the key lands in the field; a click outside closes it
/// too, and so does a paste that reaches the draft without a key. With Codex, its count of full
/// resets unfolds one row each, and a row's "Use reset" uses that one after asking; Codex's count
/// alone is one row where Codex picks, and a long list scrolls. Kore's share of each limit,
/// worked out from the run's own transcripts or rollouts (Kore's chat and another app's), starts
/// each bar hatched and is the bar's tooltip; a limit nothing used has none.
final class UsagePopup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex, countOnly, many] }

    /// Codex counting its full resets without listing them.
    static let countOnly = Variant(name: "codex-count", provider: "codex")
    /// Codex listing seven.
    static let many = Variant(name: "codex-many", provider: "codex")

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

    /// Codex's answers, trimmed from a real `account/rateLimits/read`, with a 5h window added and
    /// the reset credits listed latest first; the later one used, the 5h window is empty and the
    /// soonest left. `countOnly`: two counted, none listed; `many`: seven, out of order.
    static func codex(_ variant: Variant) -> CLIScript {
        let commands = [
            SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
            SlashCommand(name: "compact", description: "Summarize the thread to free up context", hint: "", kind: .command),
            SlashCommand(name: "pdf", description: "Read and fill PDF files", hint: "", kind: .skill),
        ]
        let account: JSONValue = ["account": ["type": "chatgpt", "email": "you@example.com", "planType": "prolite"]]
        let snapshot = { (used: Double) -> JSONValue in
            [
                "limitId": "codex",
                "primary": ["usedPercent": .number(used), "windowDurationMins": 300, "resetsAt": .number(epoch(hours: 2.2))],
                "secondary": ["usedPercent": 6, "windowDurationMins": 10080, "resetsAt": .number(epoch(hours: 4 * 24 + 2))],
                "credits": ["hasCredits": true, "unlimited": false, "balance": "47161.9384695000"],
            ]
        }
        let credit = { (id: String, days: Double) -> JSONValue in
            [
                "id": .string(id), "resetType": "codexRateLimits", "status": "available", "grantedAt": .number(epoch(hours: -24)),
                "expiresAt": .number(epoch(hours: days * 24)), "title": "Full reset", "description": "A free rate limit reset.",
            ]
        }
        let limits = { (used: Double, count: Int, credits: [JSONValue]?) -> JSONValue in
            [
                "rateLimits": snapshot(used), "rateLimitsByLimitId": ["codex": snapshot(used)],
                "rateLimitResetCredits": ["availableCount": .number(Double(count)), "credits": credits.map(JSONValue.array) ?? .null],
            ]
        }
        let (soon, late) = (credit(Self.soonest, 6 + 1.0 / 24), credit(Self.later, 20))
        let seven = limits(84, 7, Self.many7.map { credit($0.id, $0.days) })
        let (now, after): (JSONValue, JSONValue) =
            switch variant {
            case Self.countOnly: (limits(84, 2, nil), limits(0, 1, nil))
            case Self.many: (seven, seven)
            default: (limits(84, 2, [late, soon]), limits(0, 1, [soon]))
            }
        return CLIScript(
            start: [controls(commands)], usage: .codex(account: account, rateLimits: now, consume: ["outcome": "reset"], afterReset: after))
    }

    /// The reset credit that expires first, and the later one, which the reset uses.
    static let soonest = "RateLimitResetCredit_soon"
    static let later = "RateLimitResetCredit_late"
    /// Seven credits as Codex might list them, and when each expires in days; soonest first:
    /// 20h, 3d, 6d, then dates.
    static let many7: [(id: String, days: Double)] = [
        ("RateLimitResetCredit_m5", 22), ("RateLimitResetCredit_m1", 20.0 / 24), ("RateLimitResetCredit_m7", 40),
        ("RateLimitResetCredit_m2", 3), ("RateLimitResetCredit_m6", 29), ("RateLimitResetCredit_m3", 6 + 1.0 / 24),
        ("RateLimitResetCredit_m4", 15),
    ]

    private static func controls(_ commands: [SlashCommand]) -> Beat {
        .event(.controlsLoaded(ChatControls(
            models: [ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"])], model: "haiku", effort: "low",
            commands: commands)))
    }

    private static func iso(hours: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
    }

    private static func epoch(hours: Double) -> Double { Date().addingTimeInterval(hours * 3600).timeIntervalSince1970.rounded() }

    /// Kore's chat and another app's in "/work/app", Kore's with 40% of the units on Claude and
    /// 30% on Codex.
    fileprivate static let records = UsageRecords(
        claude: { _ in
            [
                .init(session: "kore-session", folder: "/work/app", kore: true, outputs: [40]),
                .init(session: "ide-session", folder: "/work/app", kore: false, outputs: [60]),
            ]
        },
        codex: { _ in
            [
                .init(thread: "kore-thread", folder: "/work/app", originator: "kore", inputs: [30]),
                .init(thread: "ide-thread", folder: "/work/app", originator: "codex_vscode", inputs: [70]),
            ]
        })

    /// Each hatch from its bar's leading edge, as wide as Kore's part of the fill (two bands at
    /// least), and the bar's tooltip saying it.
    private static func hatches(_ limits: [(title: String, used: Double, kore: Double)]) -> [any Step] {
        limits.flatMap { limit -> [any Step] in
            let id = StoryID.Composer.usageLimit(limit.title)
            let words = limit.kore < 1 ? "<1% in Kore" : "~\(Int(limit.kore.rounded()))% in Kore"
            return [
                WaitForElement(.id(id.part(.share))),
                Expect(
                    "\(limit.title)'s hatch at Kore's part of its fill",
                    found: { _ in "\(frame(id.part(.track)).map { "\($0)" } ?? "no bar"), \(frame(id.part(.share)).map { "\($0)" } ?? "no hatch")" }
                ) { _ in
                    guard let bar = frame(id.part(.track)), let hatch = frame(id.part(.share)) else { return false }
                    let fill = max(bar.width * limit.used / 100, bar.height)
                    let width = min(max(fill * limit.kore / limit.used, 6), fill)
                    return abs(hatch.minX - bar.minX) < 0.5 && abs(hatch.width - width) < 1
                },
                Expect("\(limit.title)'s tooltip “\(words)”", found: { $0.app.chat?.storyUsageBarHelp(limit.title) }) {
                    $0.app.chat?.storyUsageBarHelp(limit.title) == words
                },
            ]
        }
    }

    /// The usage row's top edge is above every other row's.
    @MainActor private static func usageFirst() -> Bool {
        guard let usage = StoryRegistry.entry(StoryID.Composer.command("usage").raw)?.frame,
            let other = StoryRegistry.entry(StoryID.Composer.command("compact").raw)?.frame
        else { return false }
        return usage.minY >= other.maxY - 0.5
    }

    /// One element's frame, in its window.
    @MainActor private static func frame(_ id: StoryID) -> CGRect? { StoryRegistry.entry(id.raw)?.frame }

    /// The unfolded resets' rows as they read, after the bars.
    @MainActor private static func resetRows(_ story: StoryContext) -> [String] { Array(story.app.chat?.storyUsage.dropFirst(2) ?? []) }
    @MainActor private static func rowsFound(_ story: StoryContext) -> String? { resetRows(story).joined(separator: " | ") }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let row = { (name: String) in Locator.id(StoryID.Composer.command(name)) }
        let popup = Locator.id(StoryID.Composer.usage)
        let tab = Locator("the chat's tab") { app in
            app.workspace.map { .success(StoryID.Tabs.tab($0.activeTab.id)) } ?? .failure(LocatorMiss("no workspace"))
        }
        let bars =
            codex
            ? ["5h limit · 84% · Resets in 2h · ~25% in Kore", "Weekly limit · 6% · Resets in 4d · ~2% in Kore"]
            : [
                "Session (5hr) · 30% · Resets in 3h · ~12% in Kore", "Weekly (7 day) · 44% · Resets in 6d · ~18% in Kore",
                "Weekly Fable · 0% · Resets in 6d",
            ]
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
            UseScript(Self.claude, for: "claude"), UseScript(Self.codex(variant), for: "codex"), Self.records, OpenFolder(), StartChat(),
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
        ]
        if variant == Self.countOnly || variant == Self.many { return steps + resetsAlone(popup: popup, row: row) }
        steps += [
            Expect("the plan and the account", found: { $0.app.chat?.storyUsageHeader }) { $0.app.chat?.storyUsageHeader == header },
            Expect("the bars with their values and resets", found: { $0.app.chat?.storyUsage.joined(separator: " | ") }) {
                $0.app.chat?.storyUsage == bars
            },
        ]
        steps += titles.map { ExpectElement(.id(StoryID.Composer.usageLimit($0))) }
        steps += Self.hatches(codex ? [("5h limit", 84, 84 * 0.3), ("Weekly limit", 6, 6 * 0.3)] : [
            ("Session (5hr)", 30.7, 30.7 * 0.4), ("Weekly (7 day)", 44, 44 * 0.4),
        ])
        if !codex {
            // Nothing used: no hatch, and the bar's tooltip stays its reset.
            steps += [
                ExpectElement(.id(StoryID.Composer.usageLimit("Weekly Fable").part(.share)), .absent),
                Expect("Weekly Fable's tooltip its reset", found: { $0.app.chat?.storyUsageBarHelp("Weekly Fable") }) {
                    $0.app.chat?.storyUsageBarHelp("Weekly Fable")?.hasPrefix("Resets ") == true
                },
            ]
        }
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
        ]
        if codex {
            // Folded at first: the count and its ⌄. Unfolded, one row each, the soonest to
            // expire first; Esc folds them and leaves the popup.
            let reset = Locator.id(StoryID.Composer.usage.part(.reset))
            let (soon, late) = (StoryID.Composer.usageReset(Self.soonest), StoryID.Composer.usageReset(Self.later))
            let resets = { (story: StoryContext) in try story.scriptedBackend().log.filter { if case .useReset = $0 { true } else { false } } }
            let spot = KeptFrame()
            steps += [
                ExpectElement(reset),
                ExpectElement(.id(soon), .absent),
                Expect("folded: the bars alone") { $0.app.chat?.isUsageResetsOpen == false && $0.app.chat?.storyUsage == bars },
                Click(reset),
                WaitForElement(.id(soon)),
                ExpectElement(.id(late)),
                Expect("two rows, the soonest first", found: Self.rowsFound) { story in
                    let rows = Self.resetRows(story)
                    return rows.count == 2 && rows[0] == "Full reset · Expires in 6d" && rows[1].hasPrefix("Full reset · Expires ")
                        && !rows[1].hasPrefix("Full reset · Expires in ")
                },
                Expect("the soonest row above the later") { _ in
                    guard let a = Self.frame(soon), let b = Self.frame(late) else { return false }
                    return a.minY >= b.maxY - 0.5
                },
                FadesEnd(),
                Snapshot("usage-resets-open"),
                Key(.escape),
                ExpectElement(.id(soon), .absent),
                ExpectElement(popup),
                // "Use reset" on the second row asks in that row; a "Yes" as quick as a double click's
                // second half does nothing, and Esc or "No, go back" take the question back.
                Click(reset),
                WaitForElement(.id(late.part(.use))),
                Click(.id(late.part(.use))),
                WaitForElement(.id(late.part(.allow))),
                ExpectElement(.id(soon.part(.use))),
                Click(.id(late.part(.allow))),
                Expect("the quick Yes ignored", found: Self.rowsFound) { story in
                    try resets(story).isEmpty && Self.resetRows(story).last == "Full reset · Use this reset?"
                },
                FadesEnd(),
                Snapshot("usage-reset-confirm"),
                Key(.escape),
                WaitForElement(.id(late.part(.use))),
                ExpectElement(.id(soon)),
                // "Use reset" pressed twice over: the second lands on "No, go back", which sits
                // where "Use reset" was, "Yes" clear of it; nothing is used.
                Expect("Use reset's place noted") { _ in
                    spot.frame = Self.frame(late.part(.use))
                    return spot.frame != nil
                },
                Press(.id(late.part(.use))),
                WaitForElement(.id(late.part(.cancel))),
                Expect("No, go back where Use reset was, Yes clear of it") { _ in
                    guard let use = spot.frame, let no = Self.frame(late.part(.cancel)), let yes = Self.frame(late.part(.allow))
                    else { return false }
                    return no.contains(CGPoint(x: use.midX, y: use.midY)) && yes.maxX <= use.minX
                },
                Press(.id(late.part(.cancel))),
                WaitForElement(.id(late.part(.use))),
                ExpectElement(.id(late.part(.allow)), .absent),
                Expect("nothing used yet") { try resets($0).isEmpty },
                // Asked again, Yes past a double click uses that one reset; the row says so in
                // its place, and the limits read again drop the count.
                Click(.id(late.part(.use))),
                WaitForElement(.id(late.part(.allow))),
                Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.chat?.storyUsageConfirmable == true },
                Click(.id(late.part(.allow))),
                Expect("one reset used, the second row's", found: { story in (try? resets(story)).map { "\($0)" } }) {
                    try resets($0) == [.useReset(credit: Self.later)]
                },
                Expect("the limits read again: the 5h window empty, one reset left", found: { $0.app.chat?.storyUsageExtras }) { story in
                    story.app.chat?.storyUsage.first?.hasPrefix("5h limit · 0% · ") == true
                        && story.app.chat?.storyUsageExtras.hasSuffix(" · 1 full reset available") == true
                },
                Expect("the used row in its place, saying so", found: Self.rowsFound) { story in
                    Self.resetRows(story) == ["Full reset · Expires in 6d", "Full reset · Usage reset."]
                },
                ExpectElement(.id(late.part(.use)), .absent),
                ExpectElement(.id(soon.part(.use))),
                FadesEnd(),
                Snapshot("usage-reset-done"),
                // Esc folds them, then (below) closes the popup.
                Key(.escape),
                ExpectElement(.id(late), .absent),
                ExpectElement(popup),
            ]
        }
        steps += [
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
            Expect("the account read again") { try $0.scriptedBackend().log.filter { $0 == .usage }.count == (codex ? 3 : 2) },
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

    /// Codex's count alone (one row, Codex picks; Return never confirms) or seven listed (the
    /// list scrolls at four and a half rows); Esc folds them, then closes the popup.
    private func resetsAlone(popup: Locator, row: (String) -> Locator) -> [any Step] {
        let reset = Locator.id(StoryID.Composer.usage.part(.reset))
        let resets = { (story: StoryContext) in try story.scriptedBackend().log.filter { if case .useReset = $0 { true } else { false } } }
        var steps: [any Step] = [WaitForElement(reset), Click(reset)]
        if variant == Self.countOnly {
            let any = StoryID.Composer.usageReset(nil)
            steps += [
                WaitForElement(.id(any)),
                Expect("one row for the count", found: Self.rowsFound) { Self.resetRows($0) == ["Full reset · 2 available"] },
                Click(.id(any.part(.use))),
                WaitForElement(.id(any.part(.allow))),
                // Return closes it and never confirms.
                Key(.returnKey),
                ExpectElement(popup, .absent),
                Expect("nothing used") { try resets($0).isEmpty },
                // Each open starts folded.
                Press(.id(StoryID.Composer.slash)),
                Press(row("usage")),
                WaitForElement(popup),
                WaitForElement(reset),
                ExpectElement(.id(any), .absent),
                Click(reset),
                WaitForElement(.id(any.part(.use))),
                Click(.id(any.part(.use))),
                WaitForElement(.id(any.part(.allow))),
                Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.chat?.storyUsageConfirmable == true },
                Click(.id(any.part(.allow))),
                Expect("one reset used, Codex's pick", found: { story in (try? resets(story)).map { "\($0)" } }) {
                    try resets($0) == [.useReset(credit: nil)]
                },
                Expect("the limits read again, one left, the row saying so", found: Self.rowsFound) { story in
                    story.app.chat?.storyUsageExtras.hasSuffix(" · 1 full reset available") == true
                        && Self.resetRows(story) == ["Full reset · Usage reset."]
                },
            ]
        } else {
            let ids = ["m1", "m2", "m3", "m4", "m5", "m6", "m7"].map { StoryID.Composer.usageReset("RateLimitResetCredit_" + $0) }
            let (first, last) = (ids[0], ids[6])
            steps += [
                WaitForElement(.id(first)),
                Expect("seven rows, the soonest first", found: Self.rowsFound) { story in
                    let rows = Self.resetRows(story)
                    let soonest = ["Full reset · Expires in 20h", "Full reset · Expires in 3d", "Full reset · Expires in 6d"]
                    let dated = rows.dropFirst(3).allSatisfy { !$0.hasPrefix("Full reset · Expires in ") }
                    return rows.count == 7 && Array(rows.prefix(3)) == soonest && dated
                        && rows.allSatisfy { $0.hasPrefix("Full reset · Expires ") }
                },
                Expect("in that order") { _ in
                    let frames = ids.compactMap(Self.frame)
                    return frames.count == 7 && zip(frames, frames.dropFirst()).allSatisfy { $0.minY >= $1.maxY - 0.5 }
                },
                Expect("the list stops short of the last row") { _ in
                    guard let card = Self.frame(StoryID.Composer.usage), let row = Self.frame(last) else { return false }
                    return row.minY < card.minY
                },
                FadesEnd(),
                Snapshot("usage-resets-many"),
                Scroll(.id(last), to: .bottom),
                Expect("scrolled to it") { _ in
                    guard let card = Self.frame(StoryID.Composer.usage), let row = Self.frame(last) else { return false }
                    return row.minY >= card.minY
                },
            ]
        }
        return steps + [
            Key(.escape),
            ExpectElement(.id(StoryID.Composer.usageReset(nil)), .absent),
            ExpectElement(popup),
            Key(.escape),
            ExpectElement(popup, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
    }
}

/// The Usage popup's extended view: its button opens a card over the chat (the popup closes)
/// with the limits on top, the first picked, and under them that limit's distribution: In
/// Kore, Kore's chats largest first (this chat as "This chat", another with its agent), Outside
/// Kore, and a line on how far to trust it. ↓ ↑ and a click pick another limit; a limit nothing
/// of Kore's used says so. Esc closes it and the composer has its focus again; a click outside
/// closes it too, and a click on a chat goes to that chat.
final class UsageExtendedView: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let popup = Locator.id(StoryID.Composer.usage)
        let card = Locator.id(StoryID.UsageModal.card)
        let extended = Locator.id(StoryID.Composer.usage.part(.extended))
        let other = codex ? "kore-thread" : "kore-session"
        let records = UsageRecords(
            claude: { story in
                let (folder, chat) = (story.app.chat?.folder.path ?? "/work/app", story.app.chat?.sessionId ?? "")
                return [
                    .init(session: "kore-session", folder: folder, kore: true, outputs: [20], agent: 10, title: "Fix the race in LoginTests"),
                    .init(session: chat, folder: folder, kore: true, outputs: [10]),
                    .init(session: "ide-session", folder: folder, kore: false, outputs: [60]),
                ]
            },
            codex: { story in
                let (folder, chat) = (story.app.chat?.folder.path ?? "/work/app", story.app.chat?.sessionId ?? "")
                return [
                    .init(thread: "kore-thread", folder: folder, originator: "kore", inputs: [20], prompt: "Port the tile layout"),
                    .init(thread: "kore-child", folder: folder, originator: "kore", parent: "kore-thread", inputs: [10]),
                    .init(thread: chat, folder: folder, originator: "kore", inputs: [10]),
                    .init(thread: "ide-thread", folder: folder, originator: "codex_vscode", inputs: [60]),
                ]
            })
        // Kore 40 of 100 units: the other chat 30 (10 its agent's), this chat 10.
        let (first, second) = codex ? ("5h limit", "Weekly limit") : ("Session (5hr)", "Weekly (7 day)")
        let name = codex ? "Port the tile layout" : "Fix the race in LoginTests"
        let ledgers =
            codex
            ? [
                first: ["In Kore · ~34%", "\(name) · ~25%", "This chat · ~8%", "Outside Kore · ~50%"],
                second: ["In Kore · ~2%", "\(name) · ~2%", "This chat · <1%", "Outside Kore · ~4%"],
            ]
            : [
                first: ["In Kore · ~12%", "\(name) · ~9%", "This chat · ~3%", "Outside Kore · ~18%"],
                second: ["In Kore · ~18%", "\(name) · ~13%", "This chat · ~4%", "Outside Kore · ~26%"],
            ]
        let ledger = { (title: String) in
            Expect("\(title)'s ledger", found: { $0.app.chat.map { "\($0.storyUsagePicked ?? "none"): \($0.storyUsageLedger)" } }) { story in
                story.app.chat?.storyUsagePicked == title && story.app.chat?.storyUsageLedger == ledgers[title]
            }
        }
        let open: [any Step] = [
            Press(.id(StoryID.Composer.slash)),
            Press(.id(StoryID.Composer.command("usage"))),
            WaitForElement(popup),
            WaitForElement(.id(StoryID.Composer.usageLimit(first).part(.share))),
            Click(extended),
            WaitForElement(card),
            ExpectElement(popup, .absent),
        ]
        var steps: [any Step] = [
            UseScript(UsagePopup.claude, for: "claude"), UseScript(UsagePopup.codex(.codex), for: "codex"), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Expect("the chat has its session") { $0.app.chat?.sessionId != nil },
            records,
        ]
        steps += open
        steps += [
            Expect("the card open, the composer's focus given up") { $0.app.chat?.isUsageExtendedOpen == true },
            // The first limit picked; its ledger, largest first, this chat by that name.
            ledger(first),
            ExpectElement(.id(StoryID.UsageModal.chat(other))),
            ExpectElement(.id(StoryID.UsageModal.card.part(.outside))),
            FadesEnd(),
            Snapshot("usage-extended"),
            // ↓ picks the next limit, ↑ the one before.
            Key(.down),
            ledger(second),
            Key(.up),
            ledger(first),
            Click(.id(StoryID.UsageModal.limit(second))),
            ledger(second),
        ]
        if !codex {
            // Nothing of Kore's on the model week: one line.
            steps += [
                Click(.id(StoryID.UsageModal.limit("Weekly Fable"))),
                Expect("the model week's one line", found: { $0.app.chat?.storyUsageLedger.joined(separator: " | ") }) {
                    $0.app.chat?.storyUsageLedger == ["Nothing from Kore in this window."]
                },
                ExpectElement(.id(StoryID.UsageModal.card.part(.outside)), .absent),
            ]
        }
        steps += [
            // Esc closes it; the composer has the keys again.
            Key(.escape),
            ExpectElement(card, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
        steps += open
        steps += [
            // It opens on the limit picked last.
            Expect("the limit picked last", found: { $0.app.chat?.storyUsagePicked }) {
                $0.app.chat?.storyUsagePicked == (codex ? second : "Weekly Fable")
            },
            // Its × closes it.
            Click(.id(StoryID.UsageModal.card.part(.close))),
            ExpectElement(card, .absent),
        ]
        steps += open
        steps += [
            Click(.id(StoryID.UsageModal.limit(first))),
            ledger(first),
            // Past a double click's time, a click on the other chat goes to it, in a tab of its own.
            PastDoubleClick(),
            Click(.id(StoryID.UsageModal.chat(other))),
            ExpectElement(card, .absent),
            Expect("the other chat open", found: { $0.app.chat?.sessionId }) { $0.app.chat?.sessionId == other },
        ]
        return steps
    }
}

/// The run's records of what each request used, as the CLIs write them, half an hour ago: in
/// place of any written before, so each storyline's figures are its own. Kore's Claude sessions
/// go on Kore's list.
private struct UsageRecords: Step {
    /// A Claude session's assistant lines: its id, its folder, whether Kore wrote it, output
    /// tokens per line (all on one model), an agent's own file, and a title.
    struct Claude {
        var session: String
        var folder: String
        var kore: Bool
        var outputs: [Int]
        var agent: Int?
        var title: String?
    }

    /// A Codex thread: its id, its folder, its originator, its parent, input tokens per request,
    /// and its first prompt.
    struct Codex {
        var thread: String
        var folder: String
        var originator: String
        var parent: String?
        var inputs: [Int]
        var prompt: String?
    }

    var claude: @MainActor (StoryContext) -> [Claude] = { _ in [] }
    var codex: @MainActor (StoryContext) -> [Codex] = { _ in [] }
    var label: String { "Write the run's usage records" }

    func run(_ story: StoryContext) async throws {
        let paths = UsagePaths.current
        let files = FileManager.default
        try? files.removeItem(at: paths.claudeProjects)
        try? files.removeItem(at: paths.codexSessions)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date().addingTimeInterval(-30 * 60))
        var out: [(URL, [String])] = []
        for session in claude(story) {
            let folder = URL(fileURLWithPath: session.folder)
            let transcript = paths.claudeProjects.appendingPathComponent(ClaudeHistory.transcript(sessionId: session.session, in: folder).deletingLastPathComponent().lastPathComponent)
            func line(_ id: String, _ output: Int) -> String {
                let entry = session.kore ? "sdk-cli" : "claude-vscode"
                return #"{"type":"assistant","timestamp":"\#(stamp)","entrypoint":"\#(entry)","cwd":"\#(session.folder)","sessionId":"\#(session.session)","message":{"id":"\#(id)","model":"test-model","usage":{"input_tokens":0,"output_tokens":\#(output),"cache_read_input_tokens":0}}}"#
            }
            var lines = session.title.map { [#"{"type":"custom-title","customTitle":"\#($0)","sessionId":"\#(session.session)"}"#] } ?? []
            lines += session.outputs.enumerated().map { line("\(session.session)-m\($0.offset)", $0.element) }
            out.append((transcript.appendingPathComponent(session.session + ".jsonl"), lines))
            if let agent = session.agent {
                out.append((transcript.appendingPathComponent("\(session.session)/subagents/agent-a1.jsonl"), [line("\(session.session)-a1", agent)]))
            }
            if session.kore { KoreSessions.shared.record(cli: "claude", session: session.session, folder: folder, launch: "new") }
        }
        let day = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        let dayPath = String(format: "%04d/%02d/%02d", day.year ?? 2026, day.month ?? 1, day.day ?? 1)
        for (index, thread) in codex(story).enumerated() {
            // Each thread at its own moment: Codex tells copies of a request apart by time and total.
            let stamp = formatter.string(from: Date().addingTimeInterval(-30 * 60 + Double(index)))
            let source = thread.parent.map { #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#($0)"}}}"# } ?? #""vscode""#
            var lines = [
                #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"\#(thread.thread)","originator":"\#(thread.originator)","cwd":"\#(thread.folder)","source":\#(source)}}"#
            ]
            if let prompt = thread.prompt {
                lines.append(#"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#)
            }
            var total = 0
            for input in thread.inputs {
                total += input
                lines.append(
                    #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0}},"rate_limits":null}}"#)
            }
            out.append((paths.codexSessions.appendingPathComponent("\(dayPath)/rollout-\(thread.thread).jsonl"), lines))
        }
        for (url, lines) in out {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        await Task.detached { KoreSessions.shared.sync() }.value
    }
}

/// Where an element was, kept from one step for a later one.
@MainActor private final class KeptFrame {
    var frame: CGRect?
}

/// Waits out the popup's fades (`Motion.fade`) and a bar's move, so a snapshot shows where they end.
/// Waits out a double click's time, so the next click is a click of its own.
private struct PastDoubleClick: Step {
    var label: String { "Wait out a double click" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .seconds(NSEvent.doubleClickInterval) + .milliseconds(100)
        try await story.until("a double click's time") { ContinuousClock.now >= end }
    }
}

private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
