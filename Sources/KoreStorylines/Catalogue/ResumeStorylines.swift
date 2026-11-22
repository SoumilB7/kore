import Foundation
import KoreCore
import KoreUI
import src

/// Resume after a close (the owner via Kore-main, 2026-11-24): a chat mid-turn and one whose
/// sub-agent runs on after its turn; the window closes under them. Reopened, one quiet cue in the
/// title row offers them, "Resume with sub-agents"; Resume sends each its note, as if typed, and
/// the cue goes. × sends nothing, and the cue doesn't come back.
class WorkResumeStoryline: ChatStoryline {
    override class var isFamily: Bool { self == WorkResumeStoryline.self }
    override class var tags: Set<Tag> { [.chat, .gate] }
    /// The first chat's turn runs on until it's stopped.
    override class var script: CLIScript { CLIScript(turns: [[.startTurn, .stream(.answer, "Working on it."), .wait(.interrupt)]]) }

    /// The second chat's turn starts a helper in the background and ends; the helper runs on.
    static let helper = CLIScript(turns: [[
        .startTurn, AgentMapStories.spawn("scan", "Scan the logs", background: true), .stream(.answer, "A helper is scanning."), .finishTurn(.completed),
    ]])

    /// What a chat says once it's going again.
    static let after = CLIScript(turns: [CLIScript.reply("On it.")])

    @MainActor static func workspace(_ story: StoryContext) throws -> Workspace {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the window") }
        return workspace
    }

    /// The messages a chat's CLI was sent since the window reopened.
    @MainActor static func sent(_ story: StoryContext, tab index: Int) throws -> [String] {
        let workspace = try workspace(story)
        guard index < workspace.tabs.count, let session = workspace.tabs[index].chat?.sessionId else { return [] }
        return ScriptedWorld.shared.backend(session: session)?.log.compactMap { call -> String? in
            if case .send(let text) = call { text } else { nil }
        } ?? []
    }

    /// The saved tabs' notes, as the window's save has them now (Kore could crash here).
    @MainActor static func notes(_ story: StoryContext) throws -> [[String: Any]?] {
        let data = try workspace(story).storySaved()
        let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (saved?["tabs"] as? [[String: Any]] ?? []).map { $0["working"] as? [String: Any] }
    }

    func setUp(helper: Bool) -> [any Step] {
        [Do("Kore started by its installer (its windows are kept)") { _ in
            Workspace.storyLaunch = ["KORE_BUILD_SHA": "6d23295", "KORE_RELEASE_TAG": "v0.3.9", "KORE_SIGN_IDENTITY": "Kore"]
        }] + super.steps() + [
            Send("Fix the build"),
            Expect("the first chat working") { story in try story.activeChat().isBusy },
        ] + (helper ? [
            UseScript(Self.helper), OpenTabs(1), Send("Scan the logs"), TurnFinished(1),
            Expect("the second chat's turn over, its helper running") { story in
                let chat = try story.activeChat()
                return !chat.isBusy && chat.isWorking
            },
        ] : []) + [
            Expect("the save notes what's working, as a crash would leave it", found: { story in (try? Self.notes(story)).map { "\($0)" } }) { story in
                let notes = try Self.notes(story)
                return helper ? notes.count == 2 && notes[0] != nil && (notes[1]?["agents"] as? Int) == 1 : notes.count == 1 && notes[0] != nil
            },
            UseScript(Self.after),
            Do("the CLIs list the chats, as real ones list theirs") { story in
                let workspace = try Self.workspace(story)
                for chat in workspace.tabs.compactMap(\.chat) {
                    guard let id = chat.sessionId else { throw StoryFailure.modelMissing("a chat's session") }
                    ScriptedWorld.shared.list(id, provider: chat.provider.id, folder: workspace.folder, title: chat.title)
                }
            },
            Do("Close the window") { story in story.window?.close() },
            Expect("the window closed") { story in story.app.workspace?.window?.isVisible != true },
            OpenFolder(),
            // A person's click comes after the window has read the CLIs' lists.
            Expect("the window's lists read") { story in try Self.workspace(story).storyListsLoaded },
        ]
    }
}

final class ResumeAfterClose: WorkResumeStoryline {
    override func steps() -> [any Step] {
        setUp(helper: true) + [
            WaitForElement(.id(StoryID.Titlebar.resume.part(.use))),
            Expect("one cue: two chats, Resume with sub-agents") { story in
                let offer = try Self.workspace(story).resumeOffer
                return offer?.line == "2 chats were working when Kore closed" && offer?.action == "Resume with sub-agents"
            },
            Snapshot("resume-cue"),
            Press(.id(StoryID.Titlebar.resume.part(.use))),
            Expect("each chat sent its note, as typed", found: { story in "\((try? Self.sent(story, tab: 0)) ?? []) \((try? Self.sent(story, tab: 1)) ?? [])" }) { story in
                let plain = Workspace.resumeText(agents: 0, commands: 0)
                let agents = Workspace.resumeText(agents: 1, commands: 0)
                return try Self.sent(story, tab: 0) == [plain] && Self.sent(story, tab: 1) == [agents]
            },
            ExpectElement(.id(StoryID.Titlebar.resume), .absent),
            Expect("the offer gone, both chats' tabs still here") { story in
                let workspace = try Self.workspace(story)
                return workspace.resumeOffer == nil && workspace.tabs.compactMap(\.chat).count == 2
            },
            Snapshot("resumed"),
        ]
    }
}

final class ResumeDismissed: WorkResumeStoryline {
    override func steps() -> [any Step] {
        setUp(helper: false) + [
            WaitForElement(.id(StoryID.Titlebar.resume.part(.cancel))),
            Expect("one chat, Resume") { story in try Self.workspace(story).resumeOffer?.action == "Resume" },
            Press(.id(StoryID.Titlebar.resume.part(.cancel))),
            ExpectElement(.id(StoryID.Titlebar.resume), .absent),
            Expect("nothing sent") { story in try Self.sent(story, tab: 0).isEmpty },
            Do("Close the window again") { story in story.window?.close() },
            Expect("the window closed") { story in story.app.workspace?.window?.isVisible != true },
            OpenFolder(),
            Expect("no cue the next time") { story in
                guard try Self.workspace(story).window?.isVisible == true else { return false }
                return try Self.workspace(story).resumeOffer == nil && StoryElement(StoryID.Titlebar.resume) == nil
            },
        ]
    }
}
