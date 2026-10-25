import AppKit
import KoreUI

/// Two folder windows: + in the second opens the picker as a sheet on that window, in its
/// folder, for its chat, and the first window doesn't become key. + back in the first takes the
/// picker there, and what's picked goes to the chat whose + it was, the other getting nothing.
final class AttachPanelOwnWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let keyed = KeyWatch()
        return super.steps() + [
            OpenSecondFolder(),
            Do("Watch the first window becoming key") { story in keyed.watch(story.window) },
            ClickAttach(second: true),
            Expect("the picker a sheet on the second window, in its folder, for its chat", found: Self.shown) { story in
                guard let other = OpenSecondFolder.workspace(story) else { return false }
                return Self.open(on: other)
            },
            Expect("the first window not key") { story in !keyed.fired && story.window?.isKeyWindow != true },
            ClickAttach(second: false),
            Expect("the picker moved to the first window, in its folder, for its chat", found: Self.shown) { story in
                guard let first = story.app.workspace, let other = OpenSecondFolder.workspace(story) else { return false }
                return Self.open(on: first) && other.window?.attachedSheet == nil
            },
            Do("Pick a file in it") { story in
                let file = story.folder.appendingPathComponent("picked.txt")
                try "picked".write(to: file, atomically: true, encoding: .utf8)
                AttachPanel.storyPick([file])
            },
            Expect("the file on the first window's chat, none on the second's") { story in
                guard let other = OpenSecondFolder.workspace(story)?.activeTab.chat else { return false }
                return try story.activeChat().attachments.count == 1 && other.attachments.isEmpty && AttachPanel.open == nil
            },
            Do("Stop watching") { _ in keyed.stop() },
        ]
    }

    /// The picker is up as a sheet on `workspace`'s window, starting in its folder, for its chat.
    @MainActor static func open(on workspace: Workspace) -> Bool {
        guard let open = AttachPanel.open, let window = workspace.window else { return false }
        let start = open.panel.directoryURL?.resolvingSymlinksInPath().path
        return open.window === window && open.panel.sheetParent === window
            && start == workspace.folder.resolvingSymlinksInPath().path && open.chat === workspace.activeTab.chat
    }

    @MainActor static func shown(_ story: StoryContext) -> String? {
        guard let open = AttachPanel.open else { return "no picker" }
        return "a sheet on “\(open.panel.sheetParent?.title ?? "none")”, in \(open.panel.directoryURL?.path ?? "nil")"
    }
}

/// A second folder opened in its own window, with a chat started in it.
private struct OpenSecondFolder: Step {
    var label: String { "Open a second folder with a chat" }
    var timeout: Duration? { .seconds(15) }

    static func folder(_ story: StoryContext) -> URL { story.outputs.appendingPathComponent("second", isDirectory: true) }
    @MainActor static func workspace(_ story: StoryContext) -> Workspace? { AppProbe(folder: folder(story)).workspace }

    func run(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        let folder = Self.folder(story)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        let workspace = try await story.wait("the second folder's window") { Self.workspace(story)?.window != nil ? Self.workspace(story) : nil }
        workspace.window?.setContentSize(story.windowSize)
        guard workspace.start(provider: story.variant?.provider ?? "claude", model: nil) else {
            throw StoryFailure.modelMissing("a provider for the second chat")
        }
        _ = try await story.wait("the second chat's composer") { () -> StoryElement? in
            guard let window = workspace.window, workspace.activeTab.chat != nil else { return nil }
            return StoryElement(StoryID.Composer.attach, in: window)
        }
        try await story.idle()
    }
}

/// A click on + in the first or the second folder's window.
private struct ClickAttach: Step {
    let second: Bool
    var label: String { "Click + in the \(second ? "second" : "first") window" }

    func run(_ story: StoryContext) async throws {
        let window = second ? OpenSecondFolder.workspace(story)?.window : story.window
        guard let window else { throw StoryFailure.modelMissing("the \(second ? "second" : "first") window") }
        let element = try await story.wait("+ in that window") { StoryElement(StoryID.Composer.attach, in: window) }
        try await story.input.click(element)
    }
}

/// Whether a window has become key since `watch`.
@MainActor
private final class KeyWatch {
    private(set) var fired = false
    private var token: NSObjectProtocol?

    func watch(_ window: NSWindow?) {
        guard let window else { return }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.fired = true }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
