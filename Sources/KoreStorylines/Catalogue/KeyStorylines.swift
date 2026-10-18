import AppKit
import KoreUI

/// A turn that runs until it's stopped: a command that never ends by itself.
private let holdTurn: [Beat] = [.startTurn, .tool(name: "Bash", detail: "sleep 600", wait: .interrupt)]

/// The tab keys, pressed as keys: ⌃⇥ and ⌃⇧⇥ step round the tabs, ⌘1–8 go to one and ⌘9 to the
/// last, ⌘W closes the tab and leaves the window, a running chat's tab asks first in the tab
/// (No puts it back, Yes or a second ⌘W a moment later closes it), and ⌥⌘1 opens Welcome,
/// which ⇧⌘1 no longer does.
final class TabKeys: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: [holdTurn]) }

    /// The running chat's tab.
    private var running: UUID?

    static func active(_ n: Int) -> Expect {
        Expect("tab \(n) the active one", found: { story in
            story.app.workspace.map { w in "tab \((w.tabs.firstIndex { $0 === w.activeTab } ?? -1) + 1) of \(w.tabs.count)" }
        }) { story in
            guard let workspace = story.app.workspace, workspace.tabs.indices.contains(n - 1) else { return false }
            return workspace.activeTab === workspace.tabs[n - 1]
        }
    }

    static func tabs(_ count: Int, _ what: String) -> Expect {
        Expect(what, found: { story in story.app.workspace.map { "\($0.tabs.count) tabs" } }) { story in
            story.app.workspace?.tabs.count == count && story.window?.isVisible == true
        }
    }

    /// The menu items a chord is the shortcut of, by title.
    @MainActor static func items(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [String] {
        func walk(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item -> [String] in
                let mine = item.keyEquivalent.lowercased() == key
                    && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers
                return (mine ? [item.title] : []) + (item.submenu.map(walk) ?? [])
            }
        }
        return NSApp.mainMenu.map(walk) ?? []
    }

    static let welcome = "Welcome to Kore"

    override func steps() -> [any Step] {
        let question = { [unowned self] (part: StoryID.Part) in
            Locator("the running chat's tab › \(part.rawValue)") { [unowned self] _ in
                running.map { .success(StoryID.Tabs.tab($0).part(part)) } ?? .failure(LocatorMiss("no running chat yet"))
            }
        }
        return super.steps() + [
            StartChat(),
            Expect("the second chat's tab noted") { [unowned self] story in
                running = story.app.workspace?.activeTab.id
                return running != nil
            },
            Command(.newTab),
            Self.tabs(3, "three tabs"), Self.active(3),

            // ⌃⇥ and ⌃⇧⇥, round the ends.
            Key(KeyChord(.tab, .control)), Self.active(1),
            Key(KeyChord(.tab, .control)), Self.active(2),
            Key(KeyChord(.tab, [.control, .shift])), Self.active(1),
            Key(KeyChord(.tab, [.control, .shift])), Self.active(3),
            // ⌘1–9: ⌘9 the last, a number past the tabs nowhere.
            Key(.cmd("1")), Self.active(1),
            Key(.cmd("9")), Self.active(3),
            Key(.cmd("2")), Self.active(2),
            Key(.cmd("5")), Self.active(2),

            // ⌘W closes the tab, not the window.
            Key(.cmd("3")), Key(.cmd("w")),
            Self.tabs(2, "two tabs, the window still open"), Self.active(2),

            // A running chat's tab asks first, and No puts it back.
            Key(.cmd("2")), Send("Run the long job"),
            WaitForEvent("the command to start") { if case .toolStarted = $0 { true } else { false } },
            Key(.cmd("w")),
            WaitForElement(question(.allow)),
            Settle(), Snapshot("close-question"),
            Self.tabs(2, "both tabs still there"),
            Expect("the turn still running") { try $0.activeChat().isRunning },
            Press(question(.cancel)),
            ExpectElement(question(.allow), .absent),
            Expect("the turn still running") { try $0.activeChat().isRunning },
            // A second ⌘W at once is a held key's or a double click's, and waits.
            Key(.cmd("w")), WaitForElement(question(.allow)),
            Key(.cmd("w")),
            Self.tabs(2, "the tab still asking"),
            Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.workspace?.storyCloseConfirmable == true },
            Key(.cmd("w")),
            Self.tabs(1, "the tab closed, the window still open"),
            Expect("the running chat's tab the one gone") { [unowned self] story in
                story.app.workspace?.tabs.contains { $0.id == running } == false
            },

            // Welcome is ⌥⌘1; ⇧⌘1 is only the editor's Replace, and ⌘W only Close Tab.
            Expect("⌥⌘1 Welcome Window, nothing on ⇧⌘1, ⌘W Close Tab", found: { _ in
                "⌥⌘1 \(Self.items("1", [.command, .option])), ⇧⌘1 \(Self.items("1", [.command, .shift])), ⌘W \(Self.items("w", .command))"
            }) { _ in
                Self.items("1", [.command, .option]) == ["Welcome Window"] && Self.items("1", [.command, .shift]).isEmpty
                    && Self.items("w", .command) == ["Close Tab"]
            },
            Expect("no Welcome window yet") { _ in !NSApp.windows.contains { $0.title == Self.welcome && $0.isVisible } },
            Key(.cmdOption("1")),
            Expect("the Welcome window open") { _ in NSApp.windows.contains { $0.title == Self.welcome && $0.isVisible } },
            Expect("the Welcome window closed again") { _ in
                NSApp.windows.filter { $0.title == Self.welcome && $0.isVisible }.forEach { $0.close() }
                return true
            },
        ]
    }
}

/// Lets a fade finish before a snapshot.
private struct Settle: Step {
    var label: String { "Let the fade finish" }
    func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(400)) }
}
