import AppKit
import KoreUI

/// The Agents button opens the agent map over a chat whose reader is part way up a long
/// transcript: every agent has its row and its wires, one of them nested under another, and the
/// chat underneath keeps its rows and its place. Closing the map gives the composer back its focus,
/// with the reader still where they were.
final class AgentMapOpen: ChatStoryline {
    static let agents = ["scout", "reader", "writer"]

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
        ]
            + Self.agents.flatMap { [ExpectElement(.id(StoryID.AgentMap.row($0)), .visible), ExpectElement(.id(StoryID.AgentMap.wires($0)), .visible)] }
            + [
                Expect("the rows in tree order: the nested agent under its parent, then the next") { _ in
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

/// A stopped agent waits in the map's closed group below the tree; opened, the group shows it.
/// Run again, it leaves the group for its place in the tree, live under the open map.
final class AgentMapStopped: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        func spawn(_ id: String, _ name: String) -> Beat {
            .event(.agentSpawned(AgentInfo(
                id: id, parent: .main, toolId: nil, name: name, type: nil, model: nil, prompt: "\(name).", background: false)))
        }
        return CLIScript(turns: [
            [
                .startTurn, spawn("scout", "Scout the code"), spawn("writer", "Write the summary"),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .event(.agentFinished(id: "scout", .stopped, result: nil)),
                .stream(.answer, "The scout stopped."), .finishTurn(.completed),
            ],
            [.startTurn, .event(.agentResumed(id: "scout")), .stream(.answer, "The scout goes on."), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let scout = StoryID.AgentMap.row("scout"), writer = StoryID.AgentMap.row("writer")
        return super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(writer), .visible),
            ExpectElement(.id(StoryID.AgentMap.stopped), .visible),
            ExpectElement(.id(scout), .absent),
            Press(.id(StoryID.AgentMap.stopped)),
            ExpectElement(.id(scout), .visible),
            Expect("the stopped agent below the tree") { _ in
                guard let top = StoryElement(writer)?.frame?.maxY, let below = StoryElement(scout)?.frame?.maxY else { return false }
                return below < top
            },
            Send("Go on"), TurnFinished(2),
            ExpectElement(.id(StoryID.AgentMap.stopped), .absent),
            ExpectElement(.id(scout), .visible),
            Expect("the resumed agent back in its place, above the next") { _ in
                guard let top = StoryElement(scout)?.frame?.maxY, let below = StoryElement(writer)?.frame?.maxY else { return false }
                return top > below
            },
        ]
    }
}

/// A background agent that has finished waits in the map's closed "Done in background" group,
/// just above the stopped one; opened, the group shows it. Run again, it leaves the group for the
/// Background section, live under the open map.
final class AgentMapDoneInBackground: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        func spawn(_ id: String, _ name: String, background: Bool = true) -> Beat {
            .event(.agentSpawned(AgentInfo(
                id: id, parent: .main, toolId: nil, name: name, type: nil, model: nil, prompt: "\(name).", background: background)))
        }
        return CLIScript(turns: [
            [
                .startTurn, spawn("scout", "Scout the code"), spawn("writer", "Write the summary", background: false),
                spawn("gone", "Watch the build"),
                .event(.agentFinished(id: "writer", .completed, result: "Written")),
                .event(.agentFinished(id: "scout", .completed, result: "Scouted")),
                .event(.agentFinished(id: "gone", .stopped, result: nil)),
                .stream(.answer, "The scout is done."), .finishTurn(.completed),
            ],
            [.startTurn, .event(.agentResumed(id: "scout")), .stream(.answer, "The scout goes on."), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let scout = StoryID.AgentMap.row("scout"), writer = StoryID.AgentMap.row("writer")
        let done = StoryID.AgentMap.done, stopped = StoryID.AgentMap.stopped
        return super.steps() + [
            Send("Use some helpers"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(writer), .visible),
            ExpectElement(.id(done), .visible),
            ExpectElement(.id(stopped), .visible),
            ExpectElement(.id(StoryID.AgentMap.background), .absent),
            ExpectElement(.id(scout), .absent),
            Expect("the done group just above the stopped one") { _ in
                guard let top = StoryElement(done)?.frame, let below = StoryElement(stopped)?.frame else { return false }
                // Window coordinates: y grows upwards.
                return top.minY >= below.maxY
            },
            Press(.id(done)),
            ExpectElement(.id(scout), .visible),
            Expect("the done agent below the tree, above the stopped group") { _ in
                guard let tree = StoryElement(writer)?.frame?.maxY, let row = StoryElement(scout)?.frame,
                    let below = StoryElement(stopped)?.frame?.maxY
                else { return false }
                return row.maxY < tree && row.minY >= below
            },
            Send("Go on"), TurnFinished(2),
            ExpectElement(.id(done), .absent),
            ExpectElement(.id(StoryID.AgentMap.background), .visible),
            ExpectElement(.id(scout), .visible),
            ExpectElement(.id(stopped), .visible),
        ]
    }
}

/// Every agent stopped and the group closed, nothing is selected: the tree keeps its place at
/// the map's left, where it stays once a stopped agent is picked.
final class AgentMapAllStopped: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .agents] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .startTurn,
            .event(.agentSpawned(AgentInfo(
                id: "scout", parent: .main, toolId: nil, name: "Scout the code", type: nil, model: nil,
                prompt: "Scout the code.", background: false))),
            .event(.agentFinished(id: "scout", .stopped, result: nil)),
            .stream(.answer, "The scout stopped."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let group = StoryID.AgentMap.stopped
        return super.steps() + [
            Send("Use a helper"), TurnFinished(1), WaitIdle(),
            Press(.id(StoryID.Titlebar.agents)),
            ExpectElement(.id(group), .visible),
            Expect("the stopped group at the map's left, nothing selected") { _ in Self.atLeft(group) },
            Press(.id(group)),
            Press(.id(StoryID.AgentMap.row("scout"))),
            Expect("the stopped group still at the map's left, the agent selected") { _ in Self.atLeft(group) },
        ]
    }

    @MainActor static func atLeft(_ id: StoryID) -> Bool {
        guard let element = StoryElement(id), let frame = element.frame, let width = element.window?.frame.width else { return false }
        return frame.minX < width / 4
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
