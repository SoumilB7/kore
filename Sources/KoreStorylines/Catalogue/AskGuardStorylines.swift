import AppKit
import Foundation
import KoreUI

// What a question must not do (review of 0.3.10): wait in a closed window, let the window behind
// take keys or its title bar's buttons, or ask twice about one file; and a cut pasted twice is
// still one move.

@MainActor
private final class Answers {
    var first: Int?, second: Int?
    var window: NSWindow?
    var tabs = 0
    var chats: Set<String> = []
}

@MainActor private func answers(_ story: StoryContext) -> Answers { story.stash(Answers.self) { Answers() } }

/// The card up now, in a window that can be seen.
@MainActor private func cardSeen() -> Bool { StoryElement(StoryID.Ask.card)?.window?.isVisible == true }

/// Asked in a window that has closed since (its object still alive): the card comes up in an open
/// one, it answers, and the question after it is asked too.
final class AskInClosedWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            OpenOtherWindow(),
            Do("The other window closes; what asks still holds it") { story in
                let other = try TabPaste.windows(story).otherWorkspace()
                answers(story).window = other.window
                other.window?.close()
            },
            WaitIdle(),
            Do("Two questions, the first in the closed window") { story in
                let answers = answers(story)
                KoreAsk.storyAsk("closed-window", in: answers.window) { answers.first = $0 }
                KoreAsk.storyAsk("after-it", in: story.window) { answers.second = $0 }
            },
            Expect("the first is up, where it can be seen", found: { _ in "\(KoreAsk.storyOpen ?? "none"), in a visible window: \(cardSeen())" }) { _ in
                KoreAsk.storyOpen == "closed-window" && cardSeen()
            },
            Key(.returnKey),
            Expect("it's answered, and the next is up") { story in answers(story).first == 1 && KoreAsk.storyOpen == "after-it" && cardSeen() },
            Key(.escape),
            Expect("and answered") { story in answers(story).second == 0 && KoreAsk.storyOpen == nil },
        ]
    }
}

/// With a question up, the window's close button does nothing; the card stays and answers.
final class AskTitleBarHeld: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    /// A press on the window's close button, its release waiting in the queue for the button's tracking.
    private static let pressClose = Do("Press the window's close button") { story in
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        try press(window)
    }

    private static func press(_ window: NSWindow) throws {
        guard let button = window.standardWindowButton(.closeButton) else { throw StoryFailure.modelMissing("the close button") }
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { throw StoryFailure.other("no mouse events") }
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
    }

    override func steps() -> [any Step] {
        super.steps() + [
            // The press itself closes a window with no question up.
            OpenOtherWindow(),
            Do("Press the other window's close button") { story in
                guard let other = try TabPaste.windows(story).otherWorkspace().window else { throw StoryFailure.modelMissing("the other window") }
                answers(story).window = other
                try Self.press(other)
            },
            WaitIdle(),
            Expect("it closed") { story in answers(story).window?.isVisible == false },
            Do("A question, and its window kept to look at") { story in
                let answers = answers(story)
                answers.window = story.window
                KoreAsk.storyAsk("title-bar", in: story.window) { answers.first = $0 }
            },
            Expect("it's up") { _ in KoreAsk.storyOpen == "title-bar" && cardSeen() },
            WaitIdle(),
            Self.pressClose,
            WaitIdle(),
            Expect("the window is open and the question up", found: { story in "window \(answers(story).window?.isVisible == true), question \(KoreAsk.storyOpen ?? "none")" }) { story in
                answers(story).window?.isVisible == true && KoreAsk.storyOpen == "title-bar" && answers(story).first == nil
            },
            Key(.returnKey),
            Expect("it answers") { story in answers(story).first == 1 && KoreAsk.storyOpen == nil },
        ]
    }
}

/// One question per file: Close Tab chosen again (the menu bar's) while the first is up asks
/// nothing more, and Don't Save leaves the file on disk as it was.
final class AskOnceForAFile: FilesStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let file = "kept.txt"
    override class var files: [(path: String, text: String)] { [(file, "as saved\n")] }

    override func steps() -> [any Step] {
        [Do("Auto Save off") { _ in FileAutoSave.shared.isEnabled = false }] + super.steps() + [
            // A chat tab beside it: closing the file's tab isn't closing the window.
            Command(.newTab), Command(.toggleExplorer),
            Press(.treeRow(Self.file)), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("thrown away "),
            Expect.editor("edited, not saved") { $0.isDirty },
            Command(.closeTab),
            Expect("the question is up") { _ in KoreAsk.storyOpen == "save-tab" },
            Command(.closeTab),
            WaitIdle(),
            Press(.id(StoryID.Ask.choice("Don't Save"))),
            WaitIdle(),
            Expect("no second question", found: { _ in KoreAsk.storyOpen }) { _ in KoreAsk.storyOpen == nil },
            Expect("the file as it was") { story in
                try String(contentsOf: story.folder.appendingPathComponent(Self.file), encoding: .utf8) == "as saved\n"
            },
            Expect("the tab closed") { story in story.app.workspace?.storyActiveFile == nil },
        ]
    }
}

/// A chat held on the clipboard and a question up: ⌘V pastes nothing, ⌘T and ⌘W do nothing, ⌘.
/// stops nothing. Once it's answered, ⌘V pastes.
final class AskHoldsWindowKeys: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep 8", output: "woke", wait: .release), .stream(.answer, "Done."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            Send("Go on"),
            WaitForEvent("the command running") { if case .toolStarted(let call, _) = $0 { call.detail == "sleep 8" } else { false } },
            RightClickTab("the chat's tab", source), PickOption("Copy Chat"),
            Do("A question") { story in
                let answers = answers(story)
                answers.tabs = try TabPaste.workspace(story).tabs.count
                KoreAsk.storyAsk("keys", in: try TabPaste.workspace(story).window) { answers.first = $0 }
            },
            Expect("it's up, the chat still working") { story in let working = try source(story).chat?.isWorking == true; return KoreAsk.storyOpen == "keys" && working },
            WaitIdle(),
            // To the chat's own window, the card's (the key one can be another).
            BoxStep("⌘V, ⌘. and ⌘W in its window") { story in
                guard let window = try TabPaste.workspace(story).window else { throw StoryFailure.modelMissing("the window") }
                for key in [KeyChord.cmd("v"), .cmd("."), .cmd("w")] { try await story.input.key(key, in: window) }
            },
            WaitIdle(),
            BoxStep("A stop would have landed by now") { _ in try await Task.sleep(for: .milliseconds(1000)) },
            Expect("nothing pasted, stopped or closed behind it", found: { story in
                let w = try? TabPaste.workspace(story)
                return "\(w?.tabs.count ?? -1) tabs, was \(answers(story).tabs); transfers \(w.map { ChatPasteStory.transfers(in: $0).count } ?? -1); working \((try? source(story).chat?.isWorking) == true); closing asked \(w?.hasOverlay == true)"
            }) { story in
                let workspace = try TabPaste.workspace(story)
                let working = try source(story).chat?.isWorking == true
                return KoreAsk.storyOpen == "keys" && workspace.tabs.count == answers(story).tabs && ChatPasteStory.transfers(in: workspace).isEmpty
                    && !workspace.hasOverlay && working
            },
            Key(.escape),
            Expect("answered") { story in answers(story).first == 0 },
            // A key that got through may ask its own question, behind this one.
            BoxStep("Whatever asked behind it has its turn") { _ in try await Task.sleep(for: .milliseconds(500)) },
            Expect("nothing was asked behind it", found: { _ in KoreAsk.storyOpen }) { _ in KoreAsk.storyOpen == nil },
            Click(Self.lastAnswer),
            Key(.cmd("v")),
            Expect("now ⌘V pastes", timeout: .seconds(10)) { story in try TabPaste.workspace(story).tabs.count == answers(story).tabs + 1 },
            Do("The command ends") { _ in ScriptedWorld.shared.backend(session: session)?.release() },
            TabPaste.reset(),
        ]
    }
}

/// A question over `story.window`, its keys pressed there, then answered: the steps around what
/// must not move behind it.
@MainActor private func behindAQuestion(_ what: String, _ keys: [KeyChord], found: @escaping @MainActor (StoryContext) -> String?, unmoved: @escaping @MainActor (StoryContext) throws -> Bool) -> [any Step] {
    [
        Do("A question") { story in
            let answers = answers(story)
            KoreAsk.storyAsk("behind", in: story.window) { answers.first = $0 }
        },
        Expect("it's up") { _ in KoreAsk.storyOpen == "behind" && cardSeen() },
        WaitIdle(),
        BoxStep("\(what), in the question's window") { story in
            guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
            for key in keys { try await story.input.key(key, in: window) }
        },
        WaitIdle(),
        BoxStep("What a key did would show by now") { _ in try await Task.sleep(for: .milliseconds(500)) },
        Expect("nothing moved behind it", found: found) { story in KoreAsk.storyOpen == "behind" ? try unmoved(story) : false },
        Key(.escape),
        Expect("answered") { story in answers(story).first == 0 && KoreAsk.storyOpen == nil },
    ]
}

/// A board behind a question: its resize and detach keys do nothing; answered, they work.
final class AskHoldsBoardKeys: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }
    override class var chats: Int { 2 }

    private final class Edits { var at = 0 }

    override func steps() -> [any Step] {
        let smaller = KeyChord(.character("-"), [.control, .command])
        return super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            Do("Focus the first tile") { story in
                let model = try BoardProbe.model(story)
                model.focus(model.board.tiles.first?.id)
                story.window?.makeFirstResponder(nil)
                story.stash(Edits.self) { Edits() }.at = model.history.undoStack.count
            },
            Expect("two chats on it") { story in try BoardProbe.model(story).chats.count == 2 },
            // Not Return with modifiers: the card takes it as its own answer.
        ] + behindAQuestion("⌃⌘− and ⌥⌘T", [smaller, .cmdOption("t")], found: { story in
            (try? BoardProbe.model(story)).map { "\($0.chats.count) chats on it, \($0.history.undoStack.count) edits, were \(story.stash(Edits.self) { Edits() }.at), question \(KoreAsk.storyOpen ?? "none")" }
        }, unmoved: { story in
            let model = try BoardProbe.model(story)
            return model.chats.count == 2 && model.history.undoStack.count == story.stash(Edits.self) { Edits() }.at
        }) + [
            Key(.cmdOption("t")),
            Expect("now ⌥⌘T takes the chat off the board") { story in try BoardProbe.model(story).chats.count == 1 },
        ]
    }
}

/// A PDF behind a question: ⌘= and ⌘F are the card's; answered, ⌘= zooms the PDF.
final class AskHoldsRendererKeys: DriveFilesPDFStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }

    private final class Scale { var at: CGFloat = 0 }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Its scale") { story in story.stash(Scale.self) { Scale() }.at = story.app.workspace?.storyPDF?.scale ?? 0 },
        ] + behindAQuestion("⌘= and ⌘F", [.cmd("="), .cmd("f")], found: { story in
            "\(story.app.workspace?.storyPDF.map { "\($0)" } ?? "no PDF"), find field \(StoryElement(StoryID.Editor.PDF.find) != nil)"
        }, unmoved: { story in
            story.app.workspace?.storyPDF?.scale == story.stash(Scale.self) { Scale() }.at && StoryElement(StoryID.Editor.PDF.find) == nil
        }) + [
            Key(.cmd("=")),
            Expect("now ⌘= zooms the PDF") { story in (story.app.workspace?.storyPDF?.scale ?? 0) > story.stash(Scale.self) { Scale() }.at },
        ]
    }
}

/// A chat behind a question: ⌃` and ⌃⇧` open no terminal; answered, ⌃` does.
final class AskHoldsTerminalKeys: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let toggle = KeyChord.ctrl("`")
        return super.steps() + [
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
        ] + behindAQuestion("⌃⇧` and ⌃`", [KeyChord(.character("`"), [.control, .shift]), toggle, toggle], found: { story in
            story.app.workspace.map { "panel open \($0.storyTerminal.open), \($0.storyTerminal.count) shells" }
        }, unmoved: { story in
            story.app.workspace?.storyTerminal.open == false && story.app.workspace?.storyTerminal.count == 0
        }) + [
            Key(toggle),
            Expect("now ⌃` opens a terminal") { story in story.app.workspace?.storyTerminal.open == true && story.app.workspace?.storyTerminal.count == 1 },
        ]
    }
}

/// A cut pasted twice, quickly: one move, one chat.
final class CutPastedTwice: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        let other: @MainActor @Sendable (StoryContext) throws -> Workspace = { story in try TabPaste.windows(story).otherWorkspace() }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            OpenOtherWindow(),
            RightClickTab("the chat's tab", source), PickOption("Cut Chat"),
            BoxStep("⌘V twice in the other window, at once") { story in
                guard let window = try other(story).window else { throw StoryFailure.modelMissing("the other window") }
                window.makeFirstResponder(nil)
                try await story.input.key(.cmd("v"), in: window)
                try await story.input.key(.cmd("v"), in: window)
            },
            Expect("moved there", timeout: .seconds(10)) { story in try other(story).tabs.contains { $0.chat?.sessionId != nil } },
            Expect("nothing still held") { _ in ChatPasteStory.held == nil },
            BoxStep("Whatever else was coming has come") { _ in try await Task.sleep(for: .milliseconds(1500)) },
            Expect("one chat, once", found: { story in (try? other(story)).map { "\($0.tabs.compactMap { $0.chat?.sessionId }); bar \(ChatPasteStory.transfers(in: $0))" } }) { story in
                let other = try other(story)
                return other.tabs.compactMap { $0.chat?.sessionId }.count == 1 && ChatPasteStory.transfers(in: other).allSatisfy { $0.failure == nil }
            },
            TabPaste.reset(),
        ]
    }
}
