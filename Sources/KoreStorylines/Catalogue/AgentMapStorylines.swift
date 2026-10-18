import AppKit
import KoreUI

/// The Agents button opens the agent map over a chat whose reader is part way up a long
/// transcript: the helpers have all finished, so they wait in the closed Done group; opened, every
/// agent has its row and its wires, newest first with the nested one under its parent, and the
/// chat underneath keeps its rows and its place. Closing the map gives the composer back its focus,
/// with the reader still where they were.
final class AgentMapOpen: ChatStoryline {
    /// Top to bottom in the open Done group.
    static let agents = ["writer", "scout", "reader"]

    override class var tags: Set<Tag> { [.chat, .agents, .gate] }
    override class var script: CLIScript {
        func spawn(_ id: String, _ name: String, under parent: AgentID = .main) -> Beat {
            .event(.agentSpawned(AgentInfo(
                id: id, parent: parent, toolId: nil, name: name, type: nil, model: nil, prompt: "\(name).", background: false)))
        }
        let long = (1...30).map { "Paragraph \($0): the scripted CLI says enough here to fill a line or two of the transcript, and a little more, so it wraps." }
            .joined(separator: "\n\n")
        return CLIScript(turns: [
            [.startTurn, .stream(.answer, long, chunk: 400), .finishTurn(.completed)],
            [
                .startTurn,
                spawn("scout", "Scout the code"),
                .event(.toolStarted(ToolCall(id: "scout-read", name: "Read", detail: "notes.md", readOnly: true), agent: .sub("scout"))),
                .event(.toolFinished(id: "scout-read", output: "notes", isError: false, agent: .sub("scout"))),
                spawn("reader", "Read the notes", under: .sub("scout")),
                .stream(.answer, "The notes say three things.", agent: .sub("reader")),
                .event(.agentFinished(id: "reader", .completed, result: "Three things")),
                .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
                spawn("writer", "Write the summary"),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .stream(.answer, "The helpers are done."),
                .finishTurn(.completed),
            ],
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Tell me a lot"), TurnFinished(1), Send("Use some helpers"), TurnFinished(2),
            Scroll(.answer(turn: 1), to: .by(-300)),
            WaitIdle(),
            RememberChat(),
            // The Agents button shows once the chat has agents.
            ExpectElement(.id(StoryID.Titlebar.agents), .visible),
            Press(.id(StoryID.Titlebar.agents)),
            Expect("the agent map open", found: Self.maps) { try $0.activeChat().isAgentMapOpen },
            ExpectElement(.id(StoryID.AgentMap.ended("done")), .visible),
            ExpectElement(.id(StoryID.AgentMap.row("writer")), .absent),
            Press(.id(StoryID.AgentMap.ended("done"))),
        ]
            + Self.agents.flatMap { [ExpectElement(.id(StoryID.AgentMap.row($0)), .visible), ExpectElement(.id(StoryID.AgentMap.wires($0)), .visible)] }
            + [
                Expect("the rows newest first: the last spawned, then the first with the nested agent under it") { _ in
                    let tops = Self.agents.compactMap { StoryElement(StoryID.AgentMap.row($0))?.frame?.maxY }
                    // Window coordinates: y grows upwards.
                    return tops.count == Self.agents.count && zip(tops, tops.dropFirst()).allSatisfy { $0 > $1 }
                },
                WaitIdle(),
                ExpectChatAsItWas("under the map"),
                Press(.id(StoryID.AgentMap.close)),
                Expect("the agent map closed") { try !$0.activeChat().isAgentMapOpen },
                WaitForFocus(.id(StoryID.Composer.field)),
                ExpectChatAsItWas("after the map"),
            ]
    }
}

/// A stopped agent waits in the map's closed Stopped group, below the Done one under the hairline;
/// opened, the group shows it. Run again, it leaves the group for the running rows under the chat,
/// live under the open map.
final class AgentMapStopped: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("scout", "Scout the code"), AgentMapStories.spawn("writer", "Write the summary"),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .event(.agentFinished(id: "scout", .stopped, result: nil)),
                .stream(.answer, "The scout stopped."), .finishTurn(.completed),
            ],
            [.startTurn, .event(.agentResumed(id: "scout")), .stream(.answer, "The scout goes on."), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let scout = StoryID.AgentMap.row("scout"), writer = StoryID.AgentMap.row("writer")
        let done = StoryID.AgentMap.ended("done"), stopped = StoryID.AgentMap.ended("stopped")
        return super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(done), .visible),
            ExpectElement(.id(stopped), .visible),
            ExpectElement(.id(writer), .absent),
            ExpectElement(.id(scout), .absent),
            AgentMapStories.groups(["Done 1 · 1 foreground", "Stopped 1 · 1 foreground"]),
            Press(.id(stopped)),
            ExpectElement(.id(scout), .visible),
            Expect("the stopped agent in its group, below the done one") { _ in
                AgentMapStories.order([done, stopped, scout])
            },
            Send("Go on"), TurnFinished(2),
            ExpectElement(.id(stopped), .absent),
            ExpectElement(.id(scout), .visible),
            Expect("the resumed agent under the chat, above the groups") { _ in
                AgentMapStories.order([StoryID.AgentMap.chat, scout, done])
            },
            AgentMapStories.groups(["Done 1 · 1 foreground"]),
        ]
    }
}

/// Stop while a foreground agent runs and a background one (spawned a turn before) runs on:
/// both leave the running rows under the chat for the Stopped group, which names its split. The
/// backends end the foreground one with the turn, and the background one from its own files
/// (Claude: its meta file and stop marker, read again at the stop) or its own turn's end (Codex),
/// with no notification.
final class AgentMapInterrupted: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    /// Stop pressed while the demo runs: what the backend reports for both, then the turn's end.
    private static let stopped: [Beat] = [
        .startTurn, AgentMapStories.spawn("demo", "Stall for a while"), .wait(.interrupt),
        .event(.agentFinished(id: "demo", .stopped, result: nil)),
        .event(.agentFinished(id: "build", .stopped, result: nil)),
        .finishTurn(.interrupted),
    ]

    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("build", "Build every method", background: true), .stream(.answer, "The build runs."),
                .finishTurn(.completed),
            ],
            stopped,
        ])
    }

    /// As Codex tells it: the child is one in the background once it outlives its turn.
    static var codexScript: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("build", "Build every method"), .stream(.answer, "The build runs."),
                .event(.agentBackgrounded(id: "build")), .finishTurn(.completed),
            ],
            stopped,
        ])
    }

    override func steps() -> [any Step] {
        let build = StoryID.AgentMap.row("build"), demo = StoryID.AgentMap.row("demo")
        let group = StoryID.AgentMap.ended("stopped")
        return [UseScript(Self.codexScript, for: "codex")] + super.steps() + [
            Send("Start the build"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(build), .visible),
            Expect("the running background agent under the chat") { _ in AgentMapStories.order([StoryID.AgentMap.chat, build]) },
            Send("Use a helper"),
            WaitForEvent("the demo to start") { if case .agentSpawned(let info) = $0 { info.id == "demo" } else { false } },
            ExpectElement(.id(demo), .visible),
            Stop(),
            TurnFinished(2), WaitIdle(),
            Expect("the turn to end as interrupted") { story in
                story.chatEvents().contains { if case .turnFinished(_, .interrupted, _) = $0 { true } else { false } }
            },
            ExpectElement(.id(group), .visible),
            ExpectElement(.id(build), .absent),
            ExpectElement(.id(demo), .absent),
            AgentMapStories.groups(["Stopped 2 · 1 foreground · 1 background"]),
            Press(.id(group)),
            ExpectElement(.id(build), .visible),
            ExpectElement(.id(demo), .visible),
            Expect("the stopped agents newest first in their group") { _ in AgentMapStories.order([group, demo, build]) },
        ]
    }
}

/// Ended agents of both kinds fold into Done and Stopped, each naming its split; opened, Done
/// shows them newest first. Run again, a background agent leaves the group for the running rows
/// under the chat, live under the open map. Codex says nothing at the spawn: its child thread is a
/// background one once it outlives the turn, running under the chat until it ends.
final class AgentMapDoneInBackground: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    private static let again: [Beat] = [
        .startTurn, .event(.agentResumed(id: "scout")), .stream(.answer, "The scout goes on."), .finishTurn(.completed),
    ]

    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("scout", "Scout the code", background: true),
                AgentMapStories.spawn("writer", "Write the summary"),
                AgentMapStories.spawn("gone", "Watch the build", background: true),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
                .event(.agentFinished(id: "gone", .stopped, result: nil)),
                .stream(.answer, "The scout is done."), .finishTurn(.completed),
            ],
            again,
        ])
    }

    /// As Codex tells it: the scout still runs when the turn ends, and ends once let go. The
    /// stopped one ended in its turn, so it's a foreground one.
    static var codexScript: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("scout", "Scout the code"), AgentMapStories.spawn("writer", "Write the summary"),
                AgentMapStories.spawn("gone", "Watch the build"),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .event(.agentFinished(id: "gone", .stopped, result: nil)),
                .stream(.answer, "The scout runs on."), .event(.agentBackgrounded(id: "scout")), .finishTurn(.completed),
                .wait(.release),
                .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
            ],
            again,
        ])
    }

    override func steps() -> [any Step] {
        let scout = StoryID.AgentMap.row("scout"), writer = StoryID.AgentMap.row("writer")
        let done = StoryID.AgentMap.ended("done"), stopped = StoryID.AgentMap.ended("stopped")
        let codex = variant.provider == "codex"
        let stoppedGroup = codex ? "Stopped 1 · 1 foreground" : "Stopped 1 · 1 background"
        let running: [any Step] = [
            ExpectElement(.id(scout), .visible),
            ExpectElement(.id(done), .visible),
            AgentMapStories.groups(["Done 1 · 1 foreground", stoppedGroup]),
            Expect("the running scout under the chat, above the groups") { _ in
                AgentMapStories.order([StoryID.AgentMap.chat, scout, done])
            },
            Release(),
        ]
        return [UseScript(Self.codexScript, for: "codex")] + super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
        ]
            + (codex ? running : [])
            + [
                ExpectElement(.id(done), .visible),
                ExpectElement(.id(stopped), .visible),
                ExpectElement(.id(writer), .absent),
                ExpectElement(.id(scout), .absent),
                AgentMapStories.groups(["Done 2 · 1 foreground · 1 background", stoppedGroup]),
                Expect("the done group just above the stopped one") { _ in AgentMapStories.order([done, stopped]) },
                Press(.id(done)),
                ExpectElement(.id(scout), .visible),
                Expect("the done agents newest first, between the done and the stopped groups' rows") { _ in
                    AgentMapStories.order([done, writer, scout, stopped])
                },
                Send("Go on"), TurnFinished(2),
                ExpectElement(.id(scout), .visible),
                Expect("the resumed scout under the chat, above the groups") { _ in
                    AgentMapStories.order([StoryID.AgentMap.chat, scout, done])
                },
                AgentMapStories.groups(["Done 1 · 1 foreground", stoppedGroup]),
                ExpectElement(.id(stopped), .visible),
            ]
    }
}

/// Every agent stopped and its group closed, the newest agent shows in the detail pane, its
/// group's row holding the highlight: the tree keeps its place at the map's left, where it stays
/// once the stopped agent is picked.
final class AgentMapAllStopped: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn, AgentMapStories.spawn("scout", "Scout the code"),
            .event(.agentFinished(id: "scout", .stopped, result: nil)),
            .stream(.answer, "The scout stopped."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let group = StoryID.AgentMap.ended("stopped")
        return super.steps() + [
            Send("Use a helper"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(group), .visible),
            ExpectElement(.id(StoryID.AgentMap.open), .visible),
            Expect("the stopped group at the map's left, the newest agent in the detail pane") { _ in Self.atLeft(group) },
            Press(.id(group)),
            Press(.id(StoryID.AgentMap.row("scout"))),
            Expect("the stopped group still at the map's left, the agent selected") { story in
                try Self.atLeft(group) && story.activeChat().storyAgentMapSelected == "scout"
            },
        ]
    }

    @MainActor static func atLeft(_ id: StoryID) -> Bool {
        guard let element = StoryElement(id), let frame = element.frame, let width = element.window?.frame.width else { return false }
        return frame.minX < width / 4
    }
}

/// The map by state, for both CLIs: one turn spawns a foreground agent that finishes, one that
/// stops, and two background ones, one running and one stopped (Codex: child threads backgrounded
/// as the turn ends). The running one hangs off the chat; below the hairline, Done and Stopped
/// name their splits. Opening and closing the groups moves nothing sideways; an agent selected in
/// a group stays selected while the group is closed, and the keys go on from its row. The next
/// turn ends the running one, which folds into Done at once. The Agents button and the map's
/// header count all four agents, the stopped ones too.
final class AgentMapByState: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    private static let second: [Beat] = [
        .startTurn, .event(.agentFinished(id: "watch", .completed, result: "Watched")),
        .stream(.answer, "The watch is over."), .finishTurn(.completed),
    ]

    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("done", "Read the notes"), AgentMapStories.spawn("cut", "Draft the copy"),
                AgentMapStories.spawn("watch", "Watch the build", background: true),
                AgentMapStories.spawn("gone", "Watch the release", background: true),
                .event(.agentFinished(id: "done", .completed, result: "Read")),
                .event(.agentFinished(id: "cut", .stopped, result: nil)),
                .event(.agentFinished(id: "gone", .stopped, result: nil)),
                .stream(.answer, "One runs on."), .finishTurn(.completed),
            ],
            second,
        ])
    }

    static var codexScript: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("done", "Read the notes"), AgentMapStories.spawn("cut", "Draft the copy"),
                AgentMapStories.spawn("watch", "Watch the build"), AgentMapStories.spawn("gone", "Watch the release"),
                .event(.agentFinished(id: "done", .completed, result: "Read")),
                .event(.agentFinished(id: "cut", .stopped, result: nil)),
                .stream(.answer, "One runs on."),
                .event(.agentBackgrounded(id: "watch")), .event(.agentBackgrounded(id: "gone")), .finishTurn(.completed),
                .event(.agentFinished(id: "gone", .stopped, result: nil)),
            ],
            second,
        ])
    }

    override func steps() -> [any Step] {
        let chat = StoryID.AgentMap.chat, watch = StoryID.AgentMap.row("watch")
        let done = StoryID.AgentMap.ended("done"), stopped = StoryID.AgentMap.ended("stopped")
        let doneRow = StoryID.AgentMap.row("done"), cut = StoryID.AgentMap.row("cut"), gone = StoryID.AgentMap.row("gone")
        let frames = AgentMapStories.Frames()
        let fixed = [chat, watch, done, stopped]
        return [UseScript(Self.codexScript, for: "codex")] + super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(watch), .visible),
            ExpectElement(.id(done), .visible),
            ExpectElement(.id(stopped), .visible),
            ExpectElement(.id(doneRow), .absent),
            ExpectElement(.id(cut), .absent),
            ExpectElement(.id(gone), .absent),
            AgentMapStories.groups(["Done 1 · 1 foreground", "Stopped 2 · 1 foreground · 1 background"]),
            AgentMapStories.counts(button: "1 running", header: "4 · 1 running"),
            Expect("the chat, its running agent, then Done and Stopped") { _ in AgentMapStories.order([chat, watch, done, stopped]) },
            Expect("the rows noted") { _ in frames.note(fixed) },
            Press(.id(done)),
            Press(.id(stopped)),
            ExpectElement(.id(doneRow), .visible),
            ExpectElement(.id(gone), .visible),
            ExpectElement(.id(cut), .visible),
            Expect("each group's agents under its row, newest first") { _ in
                AgentMapStories.order([watch, done, doneRow, stopped, gone, cut])
            },
            Expect("nothing moved sideways with both groups open") { _ in frames.same(fixed) && frames.alike(watch, [doneRow, gone, cut]) },
            // Selected, then its group closed: it stays selected, the detail pane on it.
            Press(.id(cut)),
            Press(.id(stopped)),
            ExpectElement(.id(cut), .absent),
            ExpectElement(.id(StoryID.AgentMap.open), .visible),
            Expect("the agent still selected inside the closed group") { try $0.activeChat().storyAgentMapSelected == "cut" },
            // ↑ from the closed group's row: the open Done group's agent.
            Key(.up),
            Expect("↑ from the closed group's row selects the agent above it") { try $0.activeChat().storyAgentMapSelected == "done" },
            Key(.down),
            Expect("↓ onto the group's row keeps the agent selected") { try $0.activeChat().storyAgentMapSelected == "done" },
            Key(.right),
            ExpectElement(.id(cut), .visible),
            Key(.left),
            ExpectElement(.id(cut), .absent),
            Press(.id(done)),
            ExpectElement(.id(doneRow), .absent),
            Expect("nothing moved sideways with both groups closed again") { _ in frames.same(fixed) },
            Send("Go on"), TurnFinished(2),
            ExpectElement(.id(watch), .absent),
            AgentMapStories.groups(["Done 2 · 1 foreground · 1 background", "Stopped 2 · 1 foreground · 1 background"]),
            AgentMapStories.counts(button: "4 agents", header: "4"),
            Expect("nothing moved sideways as the agent ended") { _ in frames.same([chat, done, stopped]) },
        ]
    }
}

/// Failures are never folded away, for both CLIs: one turn spawns a foreground agent that
/// finishes, one that stops, one that fails, and a background one that fails (Codex: a child
/// thread backgrounded as the turn ends, failing after). The failed ones hang off the chat in red,
/// above the closed Done and Stopped groups, and stay there after the next turn. The Agents
/// button and the map's header count the same four agents, the stopped one included.
final class FailedAgentVisible: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }

    override class var script: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("notes", "Read the notes"), AgentMapStories.spawn("cut", "Draft the copy"),
                AgentMapStories.spawn("scan", "Scan the logs"), AgentMapStories.spawn("watch", "Watch the build", background: true),
                .event(.agentFinished(id: "notes", .completed, result: "Read")),
                .event(.agentFinished(id: "cut", .stopped, result: nil)),
                .event(.agentFinished(id: "scan", .failed, result: "The log is missing")),
                .event(.agentFinished(id: "watch", .failed, result: "The build broke")),
                .stream(.answer, "Two failed."), .finishTurn(.completed),
            ],
            CLIScript.reply("Noted."),
        ])
    }

    static var codexScript: CLIScript {
        CLIScript(turns: [
            [
                .startTurn, AgentMapStories.spawn("notes", "Read the notes"), AgentMapStories.spawn("cut", "Draft the copy"),
                AgentMapStories.spawn("scan", "Scan the logs"), AgentMapStories.spawn("watch", "Watch the build"),
                .event(.agentFinished(id: "notes", .completed, result: "Read")),
                .event(.agentFinished(id: "cut", .stopped, result: nil)),
                .event(.agentFinished(id: "scan", .failed, result: "The log is missing")),
                .stream(.answer, "Two failed."), .event(.agentBackgrounded(id: "watch")), .finishTurn(.completed),
                .event(.agentFinished(id: "watch", .failed, result: "The build broke")),
            ],
            CLIScript.reply("Noted."),
        ])
    }

    override func steps() -> [any Step] {
        let chat = StoryID.AgentMap.chat, scan = StoryID.AgentMap.row("scan"), watch = StoryID.AgentMap.row("watch")
        let done = StoryID.AgentMap.ended("done"), stopped = StoryID.AgentMap.ended("stopped")
        let failed: [any Step] = [
            ExpectElement(.id(scan), .visible),
            ExpectElement(.id(watch), .visible),
            ExpectElement(.id(StoryID.AgentMap.row("notes")), .absent),
            ExpectElement(.id(StoryID.AgentMap.row("cut")), .absent),
            AgentMapStories.groups(["Done 1 · 1 foreground", "Stopped 1 · 1 foreground"]),
            Expect("the failed agents under the chat, above the closed groups") { _ in
                AgentMapStories.order([chat, scan, watch, done, stopped])
            },
            AgentMapStories.counts(button: "4 agents", header: "4 · 2 failed"),
        ]
        return [UseScript(Self.codexScript, for: "codex"), PutClaudeChat()] + super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            // The title row with the Agents button's red point, then History over it.
            Snapshot("title-row"),
            Press(.id(StoryID.Titlebar.history)),
            AgentMapStories.faded(),
            Snapshot("history"),
            Press(.id(StoryID.Titlebar.history)),
            Press(.id(StoryID.Titlebar.agents)),
            AgentMapStories.faded(),
            Snapshot("agent-map-failed"),
        ]
            + failed
            + [Press(.id(StoryID.AgentMap.close)), Send("Go on"), TurnFinished(2), Press(.id(StoryID.Titlebar.agents))]
            + failed
    }
}

/// The owner's case (24 agents: 2 background running, 19 background ended, one of them stopped,
/// and the latest turn's 3 foreground demos, one stopped) and the map's two groups open, saved
/// as snapshots.
final class AgentMapOwnerCase: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        var beats: [Beat] = [.startTurn]
        for (k, name) in AgentMapStories.names.prefix(18).enumerated() {
            if k == 10 {
                beats += AgentMapStories.ended("release", "Watch the release build", background: true, .stopped, seconds: 252, tokens: 30_100)
            }
            beats += AgentMapStories.ended("bg\(k)", name, background: true, .completed, seconds: 40 + (k * 377) % 1400, tokens: 4_000 + (k * 9_311) % 180_000)
        }
        beats += [
            AgentMapStories.spawn("resume", "Resume sign-in methods build", background: true),
            .event(.agentProgress(id: "resume", AgentProgress(tokens: 371_700))),
            AgentMapStories.spawn("slow", "Fix slow open of huge chat", background: true),
            .event(.agentProgress(id: "slow", AgentProgress(tokens: 161_300))),
        ]
        beats += AgentMapStories.ended("demo1", "Foreground demo agent", background: false, .completed, seconds: 6, tokens: 20_400)
        beats += [AgentMapStories.spawn("demo2", "Foreground demo, slow one"), .event(.agentFinished(id: "demo2", .stopped, result: nil))]
        beats += AgentMapStories.ended("demo3", "Foreground demo, second", background: false, .completed, seconds: 164, tokens: 15_400)
        return CLIScript(turns: [beats + [.stream(.answer, "The demos are done."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Run the demos"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            AgentMapStories.groups(["Done 20 · 2 foreground · 18 background", "Stopped 2 · 1 foreground · 1 background"]),
            ExpectElement(.id(StoryID.AgentMap.row("slow")), .visible),
            AgentMapStories.faded(),
            Snapshot("agent-map-owner"),
            Press(.id(StoryID.AgentMap.ended("stopped"))),
            Press(.id(StoryID.AgentMap.row("demo2"))),
            ExpectElement(.id(StoryID.AgentMap.row("release")), .visible),
            AgentMapStories.faded(),
            Snapshot("agent-map-owner-stopped-open"),
        ]
    }
}

/// The big case, while its turn runs: 5 running of both kinds (one nested under another), and 43
/// ended behind two closed rows, 48 agents in all. Opened, Done keeps its nesting.
final class AgentMapBigCase: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var variants: [Variant] { [.claude] }
    static let explored = [
        "Explore the transcript store", "Read look.md §10", "Plan the usage popup", "Check Codex rate limits", "Survey storylines",
        "Find the composer focus bug", "Summarise the work ledger", "Map the theme tokens",
    ]
    override class var script: CLIScript {
        var beats: [Beat] = [.startTurn]
        for k in 0..<30 {
            beats += AgentMapStories.ended(
                "bg\(k)", AgentMapStories.names[k % AgentMapStories.names.count] + (k >= 28 ? " again" : ""), background: true,
                k == 9 || k == 21 ? .stopped : .completed, seconds: 40 + (k * 433) % 1400, tokens: 4_000 + (k * 7_919) % 180_000)
        }
        for (k, name) in explored.enumerated() {
            if k == 4 {
                beats += [AgentMapStories.spawn("fg\(k)", name)]
                beats += AgentMapStories.ended("survey1", "Read AgentMapStorylines", under: "fg\(k)", .completed, seconds: 41, tokens: 8_800)
                beats += AgentMapStories.ended("survey2", "Grep StoryID uses", under: "fg\(k)", .completed, seconds: 12, tokens: 2_000)
                beats += [.event(.agentProgress(id: "fg\(k)", AgentProgress(tokens: 52_000, duration: .seconds(212)))),
                          .event(.agentFinished(id: "fg\(k)", .completed, result: "Done"))]
            } else {
                beats += AgentMapStories.ended("fg\(k)", name, background: false, .completed, seconds: 30 + k * 31, tokens: 9_000 + k * 3_100)
            }
        }
        beats += AgentMapStories.ended("draft", "Draft login copy", background: false, .stopped, seconds: 15, tokens: 3_200)
        beats += [
            AgentMapStories.spawn("sweep", "Sweep build warnings", background: true),
            .event(.agentProgress(id: "sweep", AgentProgress(tokens: 402_900))),
            AgentMapStories.spawn("probe", "Codex login probe", background: true),
            .event(.agentProgress(id: "probe", AgentProgress(tokens: 64_000))),
            AgentMapStories.spawn("map", "Map the agent store"),
            .event(.agentProgress(id: "map", AgentProgress(tokens: 18_400))),
            AgentMapStories.spawn("read", "Read TranscriptStore", under: .sub("map")),
            .event(.agentProgress(id: "read", AgentProgress(tokens: 6_200))),
        ]
        beats += AgentMapStories.ended("grep", "Grep agentTree callers", under: "map", .completed, seconds: 9, tokens: 2_100)
        beats += [AgentMapStories.spawn("bench", "Bench tab switching"), .event(.agentProgress(id: "bench", AgentProgress(tokens: 9_900)))]
        beats += AgentMapStories.ended("theme", "Explore theme tokens", background: false, .completed, seconds: 22, tokens: 7_500)
        return CLIScript(turns: [beats + [.wait(.release), .stream(.answer, "The map is drawn."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Map the agents"),
            AgentMapStories.groups(["Done 40 · 12 foreground · 28 background", "Stopped 3 · 1 foreground · 2 background"]),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(StoryID.AgentMap.row("bench")), .visible),
            Press(.id(StoryID.AgentMap.row("read"))),
            AgentMapStories.faded(),
            Snapshot("agent-map-big"),
            Press(.id(StoryID.AgentMap.ended("done"))),
            ExpectElement(.id(StoryID.AgentMap.row("theme")), .visible),
            AgentMapStories.faded(),
            Snapshot("agent-map-big-done-open"),
            Release(), TurnFinished(1),
        ]
    }
}

/// A chat with 121 agents, 117 of them ended in the background: the map builds the rows in
/// view only. Done opened, its newest rows are built and its oldest, far below, aren't.
final class AgentMapScale: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        var beats: [Beat] = [.startTurn]
        for k in 0..<120 {
            let name = AgentMapStories.names[k % AgentMapStories.names.count] + (k >= 28 ? " \(1 + k / 28)" : "")
            if [61, 104, 117].contains(k) {
                beats += [AgentMapStories.spawn("bg\(k)", name, background: true)]
            } else {
                beats += AgentMapStories.ended(
                    "bg\(k)", name, background: true, k % 23 == 7 ? .stopped : .completed, seconds: 40 + (k * 211) % 1400,
                    tokens: 4_000 + (k * 6_007) % 180_000)
            }
        }
        beats += AgentMapStories.ended("notes", "Read the release notes", background: false, .completed, seconds: 18, tokens: 4_400)
        return CLIScript(turns: [beats + [.stream(.answer, "All in."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Run them all"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            AgentMapStories.groups(["Done 113 · 1 foreground · 112 background", "Stopped 5 · 5 background"]),
            ExpectElement(.id(StoryID.AgentMap.row("bg117")), .visible),
            ExpectElement(.id(StoryID.AgentMap.row("bg0")), .absent),
            AgentMapStories.faded(),
            Snapshot("agent-map-scale"),
            Press(.id(StoryID.AgentMap.ended("done"))),
            ExpectElement(.id(StoryID.AgentMap.row("notes")), .visible),
            Expect("the oldest done rows, far below, not built") { _ in
                StoryElement(StoryID.AgentMap.row("bg0")) == nil && StoryElement(StoryID.AgentMap.row("bg1")) == nil
            },
        ]
    }
}

/// What the agent map storylines share.
enum AgentMapStories {
    static let names = [
        "Trim usage popup copy", "Codex rate-limit probe", "Rebase on main", "Scrub cassette fixtures", "Clean build warnings",
        "Bench tab switching", "Port login flow to Codex", "Check orphaned CLIs", "Account row hover card", "Sign-out restarts chats",
        "Usage resets row", "Measure open of a big chat", "Lint storylines", "Fix composer popup frame", "Slash menu glyphs",
        "Verify landing replays", "Audit agent tab footer", "Docs pass on z-docs", "Profile scroll in history", "Check login port 1455",
        "Trace grep on fixtures", "Account popup states", "Theme token sweep", "Explorer refresh glitch", "Agents button track",
        "Rename binary for prefs", "Codex child threads", "Replay the CM-main chat",
    ]

    static func spawn(_ id: String, _ name: String, under parent: AgentID = .main, background: Bool = false) -> Beat {
        .event(.agentSpawned(AgentInfo(
            id: id, parent: parent, toolId: nil, name: name, type: nil, model: nil, prompt: "\(name).", background: background)))
    }

    /// An agent that ran for `seconds` and used `tokens`, then ended.
    static func ended(
        _ id: String, _ name: String, background: Bool, _ status: AgentStatus, seconds: Int, tokens: Int
    ) -> [Beat] {
        [
            spawn(id, name, background: background),
            .event(.agentProgress(id: id, AgentProgress(tokens: tokens, duration: .seconds(seconds)))),
            .event(.agentFinished(id: id, status, result: status == .completed ? "Done" : nil)),
        ]
    }

    static func ended(_ id: String, _ name: String, under parent: String, _ status: AgentStatus, seconds: Int, tokens: Int) -> [Beat] {
        [
            spawn(id, name, under: .sub(parent)),
            .event(.agentProgress(id: id, AgentProgress(tokens: tokens, duration: .seconds(seconds)))),
            .event(.agentFinished(id: id, status, result: status == .completed ? "Done" : nil)),
        ]
    }

    /// The map's fade in (or the transcript's under it) over, for a snapshot: a short wait.
    static func faded() -> Expect {
        let since = Since()
        return Expect("the fade over") { _ in since.elapsed() > 0.6 }
    }

    /// Seconds since it was first asked.
    final class Since: @unchecked Sendable {
        private var start: Date?
        @MainActor func elapsed() -> TimeInterval {
            let start = start ?? Date()
            self.start = start
            return Date().timeIntervalSince(start)
        }
    }

    /// The Agents button and the map's header count so.
    static func counts(button: String, header: String) -> Expect {
        Expect("the Agents button “\(button)” and the header “\(header)”", found: { story in
            (try? story.activeChat().storyAgentCounts).map { "“\($0.button)”, “\($0.header)”" }
        }) { story in
            let counts = try story.activeChat().storyAgentCounts
            return counts.button == button && counts.header == header
        }
    }

    /// The map's closed groups' rows read so.
    static func groups(_ expected: [String]) -> Expect {
        Expect("the groups “\(expected.joined(separator: "”, “"))”", found: { try? $0.activeChat().storyAgentMapGroups.joined(separator: ", ") }) {
            try $0.activeChat().storyAgentMapGroups == expected
        }
    }

    /// The elements top to bottom, each wholly below the one before. Window coordinates: y grows
    /// upwards.
    @MainActor static func order(_ ids: [StoryID]) -> Bool {
        let frames = ids.compactMap { StoryElement($0)?.frame }
        return frames.count == ids.count && zip(frames, frames.dropFirst()).allSatisfy { $0.minY >= $1.maxY - 0.5 }
    }

    /// Rows' frames noted by one step and compared by a later one: same left edge, same width.
    final class Frames: @unchecked Sendable {
        private var noted: [StoryID: CGRect] = [:]

        @MainActor func note(_ ids: [StoryID]) -> Bool {
            for id in ids {
                guard let frame = StoryElement(id)?.frame else { return false }
                noted[id] = frame
            }
            return true
        }

        @MainActor func same(_ ids: [StoryID]) -> Bool {
            ids.allSatisfy { id in
                guard let was = noted[id], let now = StoryElement(id)?.frame else { return false }
                return abs(was.minX - now.minX) < 0.5 && abs(was.width - now.width) < 0.5
            }
        }

        /// The rows span what `like` spans.
        @MainActor func alike(_ like: StoryID, _ ids: [StoryID]) -> Bool {
            guard let frame = StoryElement(like)?.frame else { return false }
            return ids.allSatisfy { id in
                guard let now = StoryElement(id)?.frame else { return false }
                return abs(frame.minX - now.minX) < 0.5 && abs(frame.width - now.width) < 0.5
            }
        }
    }
}

extension AgentMapOpen {
    /// Each folder window's chats and whether their maps are open, for a failure's report.
    @MainActor static func maps(_ story: StoryContext) -> String? {
        Workspace.all.allObjects.map { workspace in
            let open = workspace.tabs.compactMap { $0.chat?.isAgentMapOpen }.map { $0 ? "open" : "closed" }
            return "\(workspace.folder.lastPathComponent) (\(workspace.window?.isVisible == true ? "shown" : "hidden")): \(open.joined(separator: ", "))"
        }.joined(separator: "; ")
    }
}

/// Notes the active chat's rows and the row at the top of its transcript, with where it is.
struct RememberChat: Step {
    var label: String { "Remember the chat's rows and place" }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let left = TabMemory.Left(chat)
        guard left.place != nil else { throw StoryFailure.expectation("a transcript row in view") }
        story.stash(TabMemory.self) { TabMemory() }.left[chat.id] = left
    }
}

/// The active chat as `RememberChat` left it: the same rows, and the same row at the same place.
struct ExpectChatAsItWas: Step {
    let when: String
    var label: String { "Expect the chat as it was, \(when)" }
    init(_ when: String) { self.when = when }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        guard let left = story.stash(TabMemory.self, make: { TabMemory() }).left[chat.id], let place = left.place else {
            throw StoryFailure.other("no remembered chat")
        }
        do {
            try await story.until("the chat as it was") {
                chat.rows == left.rows && SwitchTab.top(of: place.id).map { abs($0 - place.top) < 0.5 } ?? false
            }
        } catch StoryFailure.timedOut {
            let top = SwitchTab.top(of: place.id)
            throw StoryFailure.expectation(
                "the chat as it was \(when): \(chat.rows.count) rows (was \(left.rows.count)), "
                    + "row top \(top.map { "\($0)" } ?? "gone") (was \(place.top))")
        }
    }
}
