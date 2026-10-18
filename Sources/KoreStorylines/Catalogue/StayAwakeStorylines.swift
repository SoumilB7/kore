import Foundation
import KoreCore
import KoreUI

/// The Stay awake cup: a click turns it on in While Agents Work, and it holds while a turn runs,
/// then lets go after the idle grace (shortened here to a second). The right-click menu's modes
/// turn it on in Always and for an hour, and Turn Off; a timer isn't kept as the mode. Every
/// state's hover line. The hold under a storyline host only records, so nothing keeps the Mac
/// awake.
final class StayAwakeCup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .wait(.release)] + Beat.answer("Done working.") + [.finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let cup = Locator.id(StoryID.Titlebar.awake)
        let mode = { (id: String) in Locator.id(StoryID.Titlebar.awakeMode(id)) }
        return super.steps() + [
            AwakeSetUp(grace: 1),
            ExpectElement(cup),
            Self.shows("off", "Stay awake", held: nil),
            // A click: on in While Agents Work, waiting with nothing running.
            Click(cup),
            Self.shows("waiting", "Awake while agents work", held: nil),
            Expect("While Agents Work", found: { _ in StoryAwake.mode }) { _ in StoryAwake.mode == "agents" },
            // A running turn holds.
            Send("Work for a while"),
            Self.shows("holding", "Keeping awake · 1 agent", held: "Kore: 1 agent working"),
            Snapshot("stay-awake-holding"),
            Release(),
            TurnFinished(1),
            // The grace after the last one ends, then it lets go.
            Self.shows("holding", "Keeping awake · ends in 1m", held: "Kore: agents just finished"),
            Self.shows("waiting", "Awake while agents work", held: nil, timeout: .seconds(5)),
            // The menu's modes.
            Press(mode("always")),
            Self.shows("holding", "Awake until turned off", held: "Kore: Stay awake is on"),
            Press(mode("1h")),
            Self.shows("holding", "Awake · 1h left", held: "Kore: Stay awake for 1 hour"),
            Press(mode("off")),
            Self.shows("off", "Stay awake", held: nil),
            // A timer isn't kept: the next click is While Agents Work again.
            Click(cup),
            Self.shows("waiting", "Awake while agents work", held: nil),
            Expect("While Agents Work", found: { _ in StoryAwake.mode }) { _ in StoryAwake.mode == "agents" },
            Click(cup),
            Self.shows("off", "Stay awake", held: nil),
            Expect("every hold let go", found: { _ in "\(StoryAwake.holds)" }) { _ in StoryAwake.holds.last == .some(nil) },
        ]
    }

    /// Its state, hover line, and what the recorded hold holds.
    static func shows(_ state: String, _ line: String, held: String?, timeout: Duration? = nil) -> Expect {
        Expect(
            "\(state): “\(line)”", timeout: timeout,
            found: { _ in "\(StoryAwake.state): “\(StoryAwake.line ?? "")”, holding \(StoryAwake.held ?? "nothing")" }
        ) { _ in
            StoryAwake.state == state && StoryAwake.line == line && StoryAwake.held == held
        }
    }
}

/// A turn that ends on the plan's limit, while Stay awake is on: its notice says "Continues at
/// …" and the cup holds for it; the × cancels it. The next limit resets in a few seconds: at the
/// reset Kore reads the plan's limits again, finds them clear, and sends "Continue" once.
final class LimitContinue: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    /// The near reset: a few seconds after the script is made.
    static func resets(in seconds: Double) -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down)) }

    static func script(_ provider: String) -> CLIScript {
        let (far, near) = (resets(in: 3600), resets(in: 8))
        let said = provider == "codex" ? "You've hit your usage limit." : "You've hit your session limit"
        let usage: UsageAnswer
        if provider == "codex" {
            let window: JSONValue = ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": .number(near.timeIntervalSince1970)]
            usage = .codex(
                account: ["account": ["type": "chatgpt", "email": "you@example.com", "planType": "plus"]],
                rateLimits: ["rateLimits": ["limitId": "codex", "primary": window]])
        } else {
            let five: JSONValue = ["utilization": 100, "resets_at": .string(ISO8601DateFormatter().string(from: near))]
            usage = .claude(
                account: ["email": "you@example.com", "subscriptionType": "Claude Max"],
                usage: ["subscription_type": "max", "rate_limits_available": true, "rate_limits": ["five_hour": five]])
        }
        return CLIScript(
            turns: [
                [.startTurn, .finishTurn(.limited(said, resetsAt: far))],
                [.startTurn, .finishTurn(.limited(said, resetsAt: near))],
                CLIScript.reply("Picked up where it stopped."),
            ],
            usage: usage)
    }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let line = Locator("the limit notice's continuation") { app in
            guard let turn = app.chat?.storyContinuesTurn else { return .failure(LocatorMiss("no continuation", pending: true)) }
            return .success(StoryID.Transcript.continues(turn))
        }
        let sends = { (story: StoryContext) in
            try story.scriptedBackend().log.filter { if case .send = $0 { true } else { false } }
        }
        return [
            UseScript(Self.script(provider), for: provider), OpenFolder(), StartChat(),
            AwakeSetUp(grace: 1),
            Press(.id(StoryID.Titlebar.awakeMode("agents"))),
            Send("Do the long task"),
            TurnFinished(1),
            ExpectElement(line),
            Expect("“Continues at …” after the notice", found: { $0.app.chat?.storyContinuesLine }) {
                $0.app.chat?.storyContinuesLine?.hasPrefix("Continues ") == true
            },
            Expect("the cup holding for it", found: { _ in StoryAwake.line }) { _ in
                StoryAwake.line?.hasPrefix("Keeping awake · continues ") == true
                    && StoryAwake.held == "Kore: a chat continues when its limit resets"
            },
            Snapshot("limit-continues"),
            // The × cancels it.
            Press(line.action(.cancel)),
            ExpectElement(line, .absent),
            Expect("no continuation left") { $0.app.chat?.storyContinuesLine == nil },
            // The owner tries again; this limit resets in a few seconds.
            Send("Try once more"),
            TurnFinished(2),
            ExpectElement(line),
            Expect("“Continue” sent once at the reset, after the limits were read again", timeout: .seconds(20), found: { story in
                (try? story.scriptedBackend().log.map { "\($0)" }.joined(separator: ", "))
            }) { story in
                let log = try story.scriptedBackend().log
                guard let read = log.lastIndex(of: .usage), let sent = log.firstIndex(of: .send("Continue")) else { return false }
                return read < sent
            },
            TurnFinished(3),
            Expect("“Continue” sent once, and nothing else by itself", found: { story in
                (try? sends(story).map { "\($0)" }.joined(separator: ", "))
            }) { story in
                try sends(story) == [.send("Do the long task"), .send("Try once more"), .send("Continue")]
            },
            ExpectElement(line, .absent),
            Expect.rows("“Continue” as the user's message") { $0.contains { $0.kind == "user" && $0.text == "Continue" } },
        ]
    }
}

/// Starts from off with a short idle grace, and leaves it off again when the storyline ends,
/// pass or fail.
private struct AwakeSetUp: Step {
    let grace: TimeInterval
    var label: String { "Stay awake off, its grace \(grace)s" }

    func run(_ story: StoryContext) async throws {
        guard StoryAwake.line != nil else { throw StoryFailure.modelMissing("Stay awake") }
        StoryAwake.reset(grace: grace)
        _ = story.stash(AwakeReset.self) { AwakeReset() }
    }
}

private final class AwakeReset: StoryFinishing {
    func finish() { StoryAwake.reset() }
}
