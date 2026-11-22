import AppKit
import Foundation
import KoreCore
import KoreUI
import src

// The menu bar's commands that no other storyline uses as a person does: Zoom Out, Close
// Window, Go to Tab, Move Tab Right and Left, Save All, Auto Save, Go to Line, Account's ⌘,,
// Stay Awake and its modes, and Quit. An item that doesn't need the window in front is picked
// from the real menu bar (or its own shortcut pressed); one that acts on the front window runs
// as its item runs it for the storyline's window (`Command`), with its shortcut checked in the
// menu bar.

// MARK: - Zoom, windows and tabs

/// View ▸ Zoom Out (⌘-) makes the whole window a step smaller; ⌘0 gives it back its own size.
final class DriveWindowZoomOut: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveWindowMenu.bound("Zoom Out", key: "-", modifiers: .command, shown: "⌘-"),
            Key(KeyChord(.character("0"), .command)),
            Expect("the window at 100%") { _ in PinchZoom.storyScale() == 1 },
            Key(KeyChord(.character("-"), .command)),
            Expect("a step smaller: 90%", found: { _ in "\(PinchZoom.storyScale())" }) { _ in abs(PinchZoom.storyScale() - 0.9) < 0.001 },
            Key(KeyChord(.character("0"), .command)),
            Expect("back to 100%") { _ in PinchZoom.storyScale() == 1 },
        ]
    }
}

/// File ▸ Close Window (⇧⌘W) closes the folder's window, its tabs with it.
final class DriveWindowCloseWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveWindowMenu.bound("Close Window", key: "w", modifiers: [.command, .shift], shown: "⇧⌘W"),
            Expect("the window open") { $0.window?.isVisible == true },
            WindowCommand(.closeWindow),
            Expect("the window closed") { story in story.app.workspace?.window?.isVisible != true },
        ]
    }
}

/// File ▸ Go to Tab: Tab 1 to Tab 8 on ⌘1–⌘8 and Last Tab on ⌘9, each showing its tab.
final class DriveWindowGoToTab: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let titles = (1...8).map { "Tab \($0)" } + ["Last Tab"]
        return super.steps() + [
            OpenTabs(2),
            Expect("Go to Tab lists Tab 1–8 and Last Tab on ⌘1–⌘9", found: { _ in
                DriveWindowMenu.submenu("Go to Tab").map { "\($0.map { "\($0.title) ⌘\($0.keyEquivalent)" })" } ?? "no Go to Tab"
            }) { _ in
                guard let items = DriveWindowMenu.submenu("Go to Tab") else { return false }
                return items.map(\.title) == titles
                    && items.map(\.keyEquivalent) == (1...9).map(String.init)
                    && items.allSatisfy { $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command }
            },
            Key(.cmd("1")), DriveWindowMenu.active(1),
            Key(.cmd("9")), DriveWindowMenu.active(3),
            Key(.cmd("2")), DriveWindowMenu.active(2),
        ]
    }
}

/// File ▸ Move Tab Left (⌃⇧PgUp) and Move Tab Right (⌃⇧PgDn) move the tab in front one place,
/// and it stays in front.
final class DriveWindowMoveTab: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    private final class Order { var ids: [UUID] = [] }

    override func steps() -> [any Step] {
        let order = Order()
        let pageUp = String(UnicodeScalar(UInt16(NSPageUpFunctionKey)).map(Character.init) ?? " ")
        let pageDown = String(UnicodeScalar(UInt16(NSPageDownFunctionKey)).map(Character.init) ?? " ")
        let placed: @MainActor (String, [Int]) -> Expect = { what, places in
            Expect(what, found: { story in story.app.workspace.map { w in "\(w.tabs.map { order.ids.firstIndex(of: $0.id) ?? -1 })" } }) { story in
                guard let workspace = story.app.workspace, order.ids.count == 3 else { return false }
                return workspace.tabs.map(\.id) == places.map { order.ids[$0] } && workspace.activeTab.id == order.ids[2]
            }
        }
        return super.steps() + [
            OpenTabs(2),
            Do("Note the three tabs") { story in order.ids = story.app.workspace?.tabs.map(\.id) ?? [] },
            DriveWindowMenu.bound("Move Tab Left", key: pageUp, modifiers: [.control, .shift], shown: "⌃⇧PgUp"),
            DriveWindowMenu.bound("Move Tab Right", key: pageDown, modifiers: [.control, .shift], shown: "⌃⇧PgDn"),
            Command(.moveTabLeft),
            placed("the third tab moved left, still in front", [0, 2, 1]),
            Command(.moveTabLeft),
            placed("and to the front of the strip", [2, 0, 1]),
            Command(.moveTabRight),
            placed("one place right again", [0, 2, 1]),
        ]
    }
}

// MARK: - Files

/// Auto Save off, two files edited: File ▸ Save All (⌥⌘S) writes both.
final class DriveWindowSaveAll: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("one.txt", "one\n"), ("two.txt", "two\n")] }

    override func steps() -> [any Step] {
        [DriveWindowAutoSave.off()] + super.steps() + [
            Command(.toggleExplorer),
            Click(.treeRow("one.txt"), count: 2), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("A "),
            Click(.treeRow("two.txt"), count: 2), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("B "),
            Expect("both edited, neither saved") { story in
                story.app.workspace?.storyFileTabs.count == 2 && story.app.workspace?.storyActiveFileDirty == true
            },
            Expect.disk("one.txt", "one\n"),
            DriveWindowMenu.bound("Save All", key: "s", modifiers: [.command, .option], shown: "⌥⌘S"),
            Command(.saveAll),
            Expect.disk("one.txt", "A one\n"),
            Expect.disk("two.txt", "B two\n"),
            Expect("nothing left unsaved") { $0.app.workspace?.storyActiveFileDirty == false },
        ]
    }
}

/// File ▸ Auto Save, picked in the menu bar, turns it on; picked again, off.
final class DriveWindowAutoSaveMenu: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("auto.txt", "auto\n")] }

    override func steps() -> [any Step] {
        [DriveWindowAutoSave.off()] + super.steps() + [
            Expect("Auto Save off, unticked") { _ in !FileAutoSave.shared.isEnabled && DriveWindowMenu.item(["Auto Save"])?.state != .on },
            DriveWindowMenuPick("Auto Save"),
            Expect("Auto Save on") { _ in FileAutoSave.shared.isEnabled },
            Command(.toggleExplorer),
            Click(.treeRow("auto.txt"), count: 2), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("saved "),
            Expect("the edit written without a Save", timeout: .seconds(10)) { story in
                (try? String(contentsOf: story.folder.appendingPathComponent("auto.txt"), encoding: .utf8)) == "saved auto\n"
            },
            DriveWindowMenuPick("Auto Save"),
            Expect("Auto Save off again") { _ in !FileAutoSave.shared.isEnabled },
        ]
    }
}

/// Go ▸ Go to Line… (⌃G): a line number and Return put the caret on that line.
final class DriveWindowGoToLine: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("lines.txt", "one\ntwo\nthree\nfour\nfive\nsix\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveWindowMenu.bound("Go to Line…", key: "g", modifiers: .control, shown: "⌃G"),
            Command(.goToLine),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText("4"), Key(.returnKey),
            Expect.editor("the caret on line 4") { $0.path == "lines.txt" && $0.caretLine == 4 },
        ]
    }
}

// MARK: - Account

/// Kore ▸ Account… (⌘,): the chat's Account popup opens, as the / menu's Account does; Esc
/// closes it.
final class DriveWindowAccountKey: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            DriveWindowMenu.bound("Account…", key: ",", modifiers: .command, shown: "⌘,"),
            ExpectElement(.id(StoryID.Composer.account), .absent),
            Key(.cmd(",")),
            WaitForElement(.id(StoryID.Composer.account)),
            Expect("Account says who's signed in", found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) {
                $0.app.chat?.storyAccount.isEmpty == false
            },
            Key(.escape),
            ExpectElement(.id(StoryID.Composer.account), .absent),
        ]
    }
}

// MARK: - Stay Awake

/// Kore ▸ Stay Awake (⌥⌘A) turns it on in its mode and off again, from the menu bar and by its
/// key; Kore ▸ Stay Awake Mode's items turn it on in theirs, the one on ticked.
final class DriveWindowStayAwakeMenu: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    @MainActor private static func awake(_ on: Bool, _ mode: String) -> Expect {
        Expect(on ? "on, in \(mode)" : "off", found: { _ in "\(StoryAwake.isOn ? "on" : "off") in \(StoryAwake.mode ?? "nothing")" }) { _ in
            StoryAwake.isOn == on && (!on || StoryAwake.mode == mode)
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Stay awake off, in While Agents Work") { story in
                guard StoryAwake.line != nil else { throw StoryFailure.modelMissing("Stay awake") }
                StoryAwake.reset(grace: 1)
                _ = story.stash(DriveWindowAwakeReset.self) { DriveWindowAwakeReset() }
            },
            Self.awake(false, "agents"),
            DriveWindowMenu.bound("Stay Awake", key: "a", modifiers: [.command, .option], shown: "⌥⌘A"),
            DriveWindowMenuPick("Stay Awake"),
            Self.awake(true, "agents"),
            Expect("Stay Awake ticked") { _ in DriveWindowMenu.item(["Stay Awake"])?.state == .on },
            Key(.cmdOption("a")),
            Self.awake(false, "agents"),
            Key(.cmdOption("a")),
            Self.awake(true, "agents"),
            DriveWindowMenuPick("Stay Awake Mode", "Always"),
            Self.awake(true, "always"),
            Expect("Always ticked, While Agents Work not") { _ in
                DriveWindowMenu.item(["Stay Awake Mode", "Always"])?.state == .on
                    && DriveWindowMenu.item(["Stay Awake Mode", "While Agents Work"])?.state != .on
            },
            DriveWindowMenuPick("Stay Awake Mode", "For 1 Hour"),
            Self.awake(true, "1h"),
            DriveWindowMenuPick("Stay Awake"),
            Self.awake(false, "agents"),
        ]
    }
}

@MainActor
private final class DriveWindowAwakeReset: StoryFinishing {
    func finish() { StoryAwake.reset() }
}

// MARK: - Quit

/// Kore ▸ Quit Kore (⌘Q): the first ⌘Q only says so, the second quits; picked from the menu
/// bar it quits at once. Quitting is only counted here.
final class DriveWindowQuitMenu: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let quits = DriveWindowQuits()
        return [
            Do("Quitting only counted") { story in
                _ = story.stash(DriveWindowQuits.self) { quits }
                QuitGuard.shared.disarm()
                QuitGuard.shared.terminate = { quits.count += 1 }
            },
        ] + super.steps() + [
            DriveWindowMenu.bound("Quit Kore", key: "q", modifiers: .command, shown: "⌘Q"),
            Expect("nothing quit yet") { _ in quits.count == 0 && !QuitGuard.shared.armed },
            // Handed to the menu in process, it isn't the app's current event, so it quits as a
            // menu's pick does. The first press's notice is QuitGuard's own (`byKey`).
            Key(.cmd("q")),
            Expect("⌘Q reached Quit Kore", found: { _ in "\(quits.count) quits" }) { _ in quits.count == 1 && !QuitGuard.shared.armed },
            Do("the key guard, as a real key presses it") { _ in QuitGuard.shared.press(byKey: true, hasWindow: true) },
            Expect("the first key arms it, quitting nothing") { _ in QuitGuard.shared.armed && quits.count == 1 },
            Do("the key again") { _ in QuitGuard.shared.press(byKey: true, hasWindow: true) },
            Expect("the second quits") { _ in !QuitGuard.shared.armed && quits.count == 2 },
            Do("Nothing pressed since") { _ in
                QuitGuard.shared.disarm()
                quits.before = quits.count
            },
            DriveWindowMenuPick("Quit Kore"),
            Expect("Quit Kore picked in the menu quits (or, taken as a key, says so)", found: { _ in "\(quits.count) quits" }) { _ in
                quits.count == quits.before + 1 && !QuitGuard.shared.armed
            },
        ]
    }
}

/// Quits counted; quitting as it was once the storyline ends.
private final class DriveWindowQuits: StoryFinishing {
    var count = 0
    var before = 0
    @MainActor func finish() {
        QuitGuard.shared.disarm()
        QuitGuard.shared.terminate = { NSApp.terminate(nil) }
    }
}

// MARK: - Shared

/// Auto Save as it was, put back when the storyline ends.
@MainActor
final class DriveWindowAutoSave: StoryFinishing {
    private var was = false

    /// Auto Save off for the storyline, as a person may have it.
    static func off() -> Do {
        Do("Auto Save off") { story in
            let kept = story.stash(DriveWindowAutoSave.self) { DriveWindowAutoSave() }
            kept.was = FileAutoSave.shared.isEnabled
            FileAutoSave.shared.isEnabled = false
        }
    }

    func finish() { FileAutoSave.shared.isEnabled = was }
}

/// Picks an item of the menu bar, by its titles from a menu down: the app's own menus, as a
/// click on them runs the item.
struct DriveWindowMenuPick: Step {
    let path: [String]
    var label: String { "Pick “\(path.joined(separator: " ▸ "))” in the menu bar" }
    init(_ path: String...) { self.path = path }

    func run(_ story: StoryContext) async throws {
        guard let found = DriveWindowMenu.find(path) else {
            throw StoryFailure.expectation("“\(path.joined(separator: " ▸ "))” in the menu bar")
        }
        guard found.menu.items[found.index].isEnabled else {
            throw StoryFailure.expectation("“\(path.joined(separator: " ▸ "))” enabled")
        }
        found.menu.performActionForItem(at: found.index)
        try await story.idle()
    }
}

/// The menu bar, as storylines read it.
@MainActor
enum DriveWindowMenu {
    /// The item at `path` (titles from any menu down), and the menu holding it.
    static func find(_ path: [String], in menu: NSMenu? = nil) -> (menu: NSMenu, index: Int)? {
        guard let menu = menu ?? NSApp.mainMenu, let first = path.first else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        for (index, item) in menu.items.enumerated() where item.title == first {
            if path.count == 1 { return (menu, index) }
            if let sub = item.submenu, let found = find(Array(path.dropFirst()), in: sub) { return found }
        }
        for item in menu.items {
            if let sub = item.submenu, let found = find(path, in: sub) { return found }
        }
        return nil
    }

    static func item(_ path: [String]) -> NSMenuItem? {
        find(path).map { $0.menu.items[$0.index] }
    }

    /// A submenu's items, by its title.
    static func submenu(_ title: String) -> [NSMenuItem]? {
        guard let menu = item([title])?.submenu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.filter { !$0.isSeparatorItem }
    }

    /// The item's shortcut, with ⇧ taken from an uppercase key as AppKit does.
    static func shortcut(_ item: NSMenuItem) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        var mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
        return (item.keyEquivalent.lowercased(), mask)
    }

    /// The menu bar's item titled `title` has the shortcut.
    static func bound(_ title: String, key: String, modifiers: NSEvent.ModifierFlags, shown: String) -> Expect {
        Expect("“\(title)” in the menu bar on \(shown)", found: { _ in
            item([title]).map { "“\($0.keyEquivalent)” with mask \($0.keyEquivalentModifierMask.rawValue)" } ?? "no such item"
        }) { _ in
            guard let item = item([title]) else { return false }
            let bound = shortcut(item)
            return bound.key == key.lowercased() && bound.modifiers == modifiers
        }
    }

    /// Tab `n` (from 1) is the one in front.
    static func active(_ n: Int) -> Expect {
        Expect("tab \(n) in front", found: { story in
            story.app.workspace.map { w in "tab \((w.tabs.firstIndex { $0 === w.activeTab } ?? -1) + 1) of \(w.tabs.count)" }
        }) { story in
            guard let workspace = story.app.workspace, workspace.tabs.indices.contains(n - 1) else { return false }
            return workspace.activeTab === workspace.tabs[n - 1]
        }
    }
}

/// Picks the open option popup's item titled `title`.
struct DriveWindowOption: Step {
    let title: String
    var label: String { "Pick “\(title)” in the popup" }
    init(_ title: String) { self.title = title }

    func run(_ story: StoryContext) async throws {
        try await WaitForElement(.id(StoryID.Options.panel)).run(story)
        let index = try await story.wait("“\(title)” in the popup") { StoryMenus.open.firstIndex(of: title) }
        try await Press(.id(StoryID.Options.item(index))).run(story)
    }
}

/// The key of the first registered element named `name[key]` with nothing after it but
/// `suffix` (an element named only once the storyline runs: a turn's, a zoom's).
@MainActor
func driveWindowKey(_ name: String, suffix: String = "") -> String? {
    let prefix = name + "["
    let tail = "]" + suffix
    return StoryRegistry.ids.sorted().lazy.compactMap { raw -> String? in
        guard raw.hasPrefix(prefix), raw.hasSuffix(tail), raw.count >= prefix.count + tail.count else { return nil }
        let key = String(raw.dropFirst(prefix.count).dropLast(tail.count))
        return key.contains("]") ? nil : key
    }.first
}

/// An element named only once the storyline runs, its name made from the key found.
@MainActor
func driveWindowNamed(_ what: String, _ name: String, suffix: String = "", _ make: @escaping @MainActor (String) -> StoryID) -> Locator {
    Locator(what) { _ in
        guard let key = driveWindowKey(name, suffix: suffix) else { return .failure(LocatorMiss("no \(what) yet", pending: true)) }
        return .success(make(key))
    }
}

// MARK: - Open Folder…

/// File ▸ Open Folder…, picked in the menu bar: the picker asks once ("Open"), and the folder
/// picked opens in a window of its own.
final class DriveWindowOpenFolderMenu: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + DriveWindowOpenFolder.steps("picked-from-menu", by: DriveWindowMenuPick("Open Folder…"))
    }
}

/// ⌘O, Open Folder…'s shortcut, does the same.
final class DriveWindowOpenFolderKey: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [DriveWindowMenu.bound("Open Folder…", key: "o", modifiers: .command, shown: "⌘O")]
            + DriveWindowOpenFolder.steps("picked-by-key", by: Key(.cmd("o")))
    }
}

/// The Welcome's Open Folder… on this Mac: the folder picked opens, and Welcome goes.
final class DriveWindowOpenFolderWelcome: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [ShowWelcome()]
            + DriveWindowOpenFolder.steps("picked-from-welcome", by: Press(.id(StoryID.Boxes.welcomeOpen))) + [
                Expect("Welcome closed") { _ in !NSApp.windows.contains { $0.title == ListKeys.welcome && $0.isVisible } },
            ]
    }
}

/// A folder made under the storyline's own, given to the folder picker; its window closed when
/// the storyline ends.
@MainActor
final class DriveWindowOpenFolder: StoryFinishing {
    private var name = ""

    static func window(_ name: String) -> Workspace? {
        Workspace.all.allObjects.first { !$0.isClosed && $0.folder.lastPathComponent == name && $0.window?.isVisible == true }
    }

    /// The folder made and given to the picker, `open` run, and what it should do.
    static func steps(_ name: String, by open: any Step) -> [any Step] {
        [
            Do("A folder for the picker to give") { story in
                let folder = story.folder.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                story.stash(DriveWindowOpenFolder.self) { DriveWindowOpenFolder() }.name = name
                StoryHost.picks = []
                StoryHost.pickedFolder = folder
            },
            Expect("no window for it yet") { _ in window(name) == nil },
            open,
            Expect("the picker shown once, its button Open", found: { _ in "\(StoryHost.picks)" }) { _ in StoryHost.picks == ["Open"] },
            Expect("the picked folder open in its own window") { _ in window(name) != nil },
        ]
    }

    func finish() {
        StoryHost.pickedFolder = nil
        if !name.isEmpty { Self.window(name)?.window?.close() }
    }
}
