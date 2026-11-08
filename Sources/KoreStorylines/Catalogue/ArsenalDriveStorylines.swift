import Foundation
import KoreLink
import KoreUI

/// Arsenal's Drive through the real `kore`: a new chat opens in a tab of its own in front with its
/// first message, as a person opens one, at a mode no freer than the caller's; another chat is
/// sent to, brought to the front, changed, stopped, its question answered and its approval denied.
/// Nothing freer than the caller, nothing of its own chat's from inside its turn, no mode raised,
/// approving stays the user's, and Drive's limits hold. Off, none of it.
final class ArsenalDrive: ChatStoryline {
    override class var tags: Set<Tag> { [.agentChannel, .gate] }
    override class var script: CLIScript {
        let efforts = ["low", "medium", "high"]
        let card = AgentChannelAll.card
        return CLIScript(
            start: [.event(.controlsLoaded(ChatControls(
                models: [
                    ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: efforts),
                    ModelOption(id: "verse", name: "Verse", resolved: "verse", efforts: efforts),
                ], model: "haiku", effort: "medium", commands: [])))],
            turns: [
                CLIScript.reply("Ready."), CLIScript.reply("Ready."),
                [.startTurn, .approval(AgentChannelAll.question, allow: Beat.answer("Got it."), deny: []), .finishTurn(.completed)],
                [.startTurn, .approval(card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed)],
                [.startTurn, .approval(card, allow: Beat.answer("Listed."), deny: []), .finishTurn(.completed)],
                CLIScript.reply("OK."),
            ])
    }

    /// Picks `prefix`'s row in `role`'s tiers popup.
    private struct PickTier: Step {
        let role: String
        let prefix: String
        var label: String { "\(role)'s tiers: \(prefix)" }
        var timeout: Duration? { .seconds(10) }

        @MainActor func run(_ story: StoryContext) async throws {
            try await story.idle()
            let chat = try AgentCast.of(story).chat(role)
            guard let tab = story.app.workspace?.tabs.first(where: { $0.chat === chat })?.id else { throw StoryFailure.modelMissing("\(role)'s tab") }
            try await Click(.id(StoryID.Tabs.arsenalTiers(tab))).run(story)
            try await WaitForElement(.id(StoryID.Options.panel)).run(story)
            let rows = StoryID.Options.rows
            guard let index = rows.firstIndex(where: { $0.title.hasPrefix(prefix) }), rows[index].enabled else {
                throw StoryFailure.expectation("an enabled “\(prefix)…” row in \(rows.map(\.title))")
            }
            try await Press(.id(StoryID.Options.item(index))).run(story)
        }
    }

    private func role(_ name: String, _ what: String, timeout: Duration? = nil, _ check: @escaping @MainActor (Chat) -> Bool) -> Expect {
        Expect(what, timeout: timeout) { story in check(try AgentCast.of(story).chat(name)) }
    }

    /// The chat in front, and a.
    private func shown(_ what: String, _ check: @escaping @MainActor (Chat, Chat) -> Bool) -> Expect {
        Expect(what) { story in check(try story.activeChat(), try AgentCast.of(story).chat("a")) }
    }

    /// The user puts `name` in or out of Plan: Claude's mode, Codex's switch.
    private func plan(_ name: String, _ on: Bool, codex: Bool, back: String) -> Do {
        Do("the user puts \(name) \(on ? "in" : "out of") Plan") { story in
            let chat = try AgentCast.of(story).chat(name)
            if codex { chat.setPlanMode(on) } else { chat.storySetMode(on ? "plan" : back) }
        }
    }

    override func steps() -> [any Step] {
        let directory = URL(fileURLWithPath: "/tmp/kad-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codex = variant == .codex
        let a = KoreCaller.chat("a")
        let name = codex ? "Codex" : "Claude"
        // b's mode, the lowest but Plan (Manual, Ask for approval), and the one above it.
        let low = codex ? "askForApproval" : "default"
        let higher = codex ? "approveForMe" : "acceptEdits"
        let drive = "only you drive it"
        let sends = (1...11).map { RawLines.cmd("s\($0)", "chat.send", "{\"chat\":\"{b}\",\"text\":\"more \($0)\"}") }
        return super.steps() + [
            Do("a's chat, at a socket of this run's, Arsenal allowed") { story in
                let cast = AgentCast.of(story)
                cast.directory = directory
                cast.chats["a"] = try story.activeChat()
                AgentChannel.directory = directory
                AgentGrants.stopAll()
                Arsenal.shared.setAllowed(true)
                Arsenal.shared.storyHover = true
            },
            SendTo("a", "hello"), TurnsDone("a", 1),
            Do("a in \(codex ? "Full access" : "Manual")") { story in try AgentCast.of(story).chat("a").storySetMode(codex ? "fullAccess" : "default") },
            Key(.cmdOption("k")),
            PickTier(role: "a", prefix: "Own:"),
            KoreAs(["new", "hi"], a, "Own can't open a chat", status: 5, says: "doesn't cover that"),
            PickTier(role: "a", prefix: "Drive:"),
            role("a", "Drive") { $0.arsenal == .drive },

            // A new chat, as a person opens one: its own tab, in front, its message sent with who sent
            // it, its Arsenal off, its mode no freer than a's.
            KoreAs(["new", "hello there"], a, "a new chat with a message", expect: ["Opened a \(name) chat. Sent."]),
            shown("a new tab in front, Arsenal off, no freer than a") { shown, a in shown !== a && shown.arsenal == nil && shown.noFreer(than: a) },
            Do("b is the new chat") { story in AgentCast.of(story).chats["b"] = try story.activeChat() },
            Expect.rows("b has the message, and who sent it") { rows in
                rows.contains { $0.kind == "notice" && $0.text.hasPrefix("Arsenal · sent by") } && rows.contains { $0.kind == "user" && $0.text == "hello there" }
            },
            TurnsDone("b", 1),
            Do("the user leaves b in \(low)") { story in try AgentCast.of(story).chat("b").storySetMode(low) },

            // Tabs; a message; a change; a mode lowered, never raised.
            KoreAs(["tab", "{a}"], a, "a's tab to the front", expect: ["In front."]),
            shown("a in front") { shown, a in shown === a },
            KoreAs(["send", "{b}", "second"], a, "a message to b", expect: ["Sent."]),
            TurnsDone("b", 2),
            KoreAs(["model", "{b}", "verse"], a, "b's model", expect: ["Model Verse."]),
            role("b", "b on Verse") { $0.storyModel == "verse" },
            KoreAs(["mode", "{b}", higher], a, "raising b's mode is the user's", status: 1, says: "Only you can raise a chat's mode."),
            role("b", "b's mode as it was") { $0.mode == low && !$0.storyPlanning },
            KoreAs(["mode", "{b}", "plan"], a, "b lowered to Plan", expect: ["Mode Plan."]),
            role("b", "b planning") { $0.storyPlanning },
            plan("b", false, codex: codex, back: low),
            KoreAs(["send", "{a}", "me"], a, "not to itself", status: 1, says: "Not this chat"),
            // "/" commands are the user's: Kore runs /plan (Codex's Plan switch) and /compact itself.
            KoreAs(["send", "{b}", "/plan"], a, "no /plan", status: 1, says: "Only you send"),
            KoreAs(["send", "{b}", "  /compact now"], a, "no /compact", status: 1, says: "Only you send"),
            role("b", "b not planning, not compacting") { !$0.storyPlanning && !$0.isBusy },

            // A question card in b: answered by its option; the card goes and the turn goes on.
            KoreAs(["send", "{b}", "ask"], a, "b asks", expect: ["Sent."]),
            role("b", "b's question") { $0.pendingApprovals.contains { $0.id == "q1" } },
            KoreAs(["pending", "{b}"], a, "the card's id", expect: ["· card q1"]),
            KoreAs(["answer", "{b}", "q1", "Red", "Blue"], a, "two answers to one question", status: 1, says: "asks 1 question(s)"),
            KoreAs(["answer", "{b}", "q1", "Blue"], a, "the answer", expect: ["Answered."]),
            role("b", "b's card gone") { $0.pendingApprovals.isEmpty },
            TurnsDone("b", 3),

            // An approval card: never allowed, denied as any card can be.
            KoreAs(["send", "{b}", "list it"], a, "b wants to run something", expect: ["Sent."]),
            role("b", "b's approval") { $0.pendingApprovals.contains { $0.id == "ls1" } },
            KoreAs(["answer", "{b}", "ls1", "Allow"], a, "allowing is the user's", status: 1, says: "Only you approve this"),
            role("b", "still waiting on the user") { $0.pendingApprovals.contains { $0.id == "ls1" } },
            KoreAs(["answer", "{b}", "ls1", "--deny"], a, "denied", expect: ["Denied."]),
            role("b", "b's approval gone") { $0.pendingApprovals.isEmpty },
            TurnsDone("b", 4),

            // A turn waiting on the user: stopped.
            KoreAs(["send", "{b}", "list it again"], a, "b waits again", expect: ["Sent."]),
            role("b", "b's approval again") { $0.pendingApprovals.contains { $0.id == "ls1" } },
            KoreAs(["stop", "{b}"], a, "b stopped", expect: ["Stopped."]),
            role("b", "b idle") { !$0.isBusy },
        ] + (codex ? [
            // Codex's Plan restricts nothing: a planning is still in Full access, and reaches b.
            plan("a", true, codex: true, back: low),
            KoreAs(["send", "{b}", "planned"], a, "a planning still reaches b", expect: ["Sent."]),
            plan("a", false, codex: true, back: low),
        ] : [
            // Don't ask refuses what Manual would ask: under Manual.
            Do("the user puts b in Don't ask") { story in try AgentCast.of(story).chat("b").storySetMode("dontAsk") },
            KoreAs(["send", "{b}", "quiet"], a, "Don't ask is under Manual", expect: ["Sent."]),
            Do("b back in Manual") { story in try AgentCast.of(story).chat("b").storySetMode("default") },
        ]) + [
            role("b", "b idle again", timeout: .seconds(30)) { !$0.isBusy },

            // Ten messages a minute (a's thirty commands a minute: a fresh minute for both).
            MinuteWait(seconds: 61),
            RawLines(sends, replies: sends.count, a, "the eleventh message in a minute") { replies, _ in
                let results = replies.filter { $0["id"] is String }
                return results.count == 11 && results.prefix(10).allSatisfy { $0["ok"] as? Bool == true } && results.last?["code"] as? String == "limit"
            },
            role("b", "b done with them", timeout: .seconds(30)) { !$0.isBusy && $0.queuedCount == 0 },

            KoreAs(["new", "--model", "nope"], a, "a model the CLI doesn't list", status: 1, says: "offers:"),
        ] + (codex ? [
            // A Codex caller is in Full access, Plan or not: nothing is freer.
            plan("a", true, codex: true, back: low),
            KoreAs(["new"], a, "a new chat", expect: ["Opened a Codex chat."]),
            shown("in front, Arsenal off") { shown, a in shown !== a && shown.arsenal == nil && shown.noFreer(than: a) },
            plan("a", false, codex: true, back: low),
            KoreAs(["new"], a, "a third", expect: ["Opened a Codex chat."]),
        ] : [
            // a in Plan: b, in Manual, is freer; a new chat starts planning.
            plan("a", true, codex: false, back: low),
            role("a", "a planning") { $0.storyPlanning },
            KoreAs(["send", "{b}", "hi"], a, "b is freer than a", status: 5, says: drive),
            KoreAs(["new", "--mode", low], a, "a chat freer than a", status: 1, says: "above your own mode"),
            KoreAs(["new"], a, "a new chat, capped", expect: ["Opened a Claude chat."]),
            shown("in front, planning like a, Arsenal off") { shown, a in shown !== a && shown.storyPlanning && shown.arsenal == nil },
            Do("c is that chat") { story in AgentCast.of(story).chats["c"] = try story.activeChat() },

            // "Allow commands in Plan" approves commands by itself: freer than a's plain Plan.
            Do("the user turns on Allow commands in Plan for c") { story in try AgentCast.of(story).chat("c").storySetPlanAllow(true) },
            KoreAs(["send", "{c}", "hi"], a, "c's Plan approves by itself", status: 5, says: drive),
            plan("a", false, codex: false, back: low),

            // Edit automatically accepts edits Auto would review: not under Auto.
            Do("the user puts a in Auto, b in Edit automatically") { story in
                let cast = AgentCast.of(story)
                try cast.chat("a").storySetMode("auto")
                try cast.chat("b").storySetMode("acceptEdits")
            },
            KoreAs(["send", "{b}", "hi"], a, "Edit automatically isn't under Auto", status: 5, says: drive),

            // Codex from Claude: Ask for approval runs commands in the folder by itself, above Manual.
            Do("a back in Manual") { story in try AgentCast.of(story).chat("a").storySetMode("default") },
            KoreAs(["new", "--codex"], a, "no Codex chat from Manual", status: 1, says: "Only you can open a Codex chat"),
            Do("the user puts a in Auto") { story in try AgentCast.of(story).chat("a").storySetMode("auto") },
            KoreAs(["new", "--codex"], a, "a Codex chat from Auto", expect: ["Opened a Codex chat."]),
            shown("a Codex chat, no freer than a") { shown, a in shown.provider.id == "codex" && shown.noFreer(than: a) && !shown.storyPlanning },
            Do("x is that chat; the user leaves it in Ask for approval, a in Manual") { story in
                let cast = AgentCast.of(story)
                let x = try story.activeChat()
                cast.chats["x"] = x
                x.storySetMode("askForApproval")
                try cast.chat("a").storySetMode("default")
            },
            KoreAs(["send", "{x}", "hi"], a, "Ask for approval is above Manual", status: 5, says: drive),
            // Codex's Plan restricts nothing: x planning in Full access is Full access.
            Do("the user puts x in Full access and Plan, a in Auto") { story in
                let cast = AgentCast.of(story)
                let x = try cast.chat("x")
                x.storySetMode("fullAccess")
                x.setPlanMode(true)
                try cast.chat("a").storySetMode("auto")
            },
            role("x", "x planning in Full access") { $0.storyPlanning && $0.controls.mode == "fullAccess" },
            KoreAs(["send", "{x}", "hi"], a, "x's Plan doesn't lower it", status: 5, says: drive),
            KoreAs(["mode", "{x}", "plan"], a, "nor reach it for a mode", status: 5, says: drive),
        ]) + [
            // Three new chats an hour.
            KoreAs(["new"], a, "a fourth within the hour", status: 1, says: "3 new chats an hour"),

            // Off: nothing reaches anything.
            PickTier(role: "a", prefix: "Off"),
            role("a", "a off") { $0.arsenal == nil },
            KoreAs(["send", "{b}", "hi"], a, "off", status: 5, says: "agent control is off"),
        ]
    }
}
