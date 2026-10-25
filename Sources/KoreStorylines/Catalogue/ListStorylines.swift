import AppKit
import KoreCore
import KoreUI

/// The rows lit right now: the `.lit` marks a one-highlight list puts on its lit row, under `area`.
@MainActor private func litRows(_ area: String) -> [String] {
    StoryRegistry.ids.filter { $0.hasPrefix(area + ".") && $0.hasSuffix(".lit") }.map { String($0.dropLast(".lit".count)) }
}

/// The rows a one-highlight list lights, as one check: exactly `row`.
private func onlyLit(_ what: String, area: String, _ row: StoryID) -> Expect {
    Expect(what, found: { _ in litRows(area).joined(separator: ", ") }) { _ in litRows(area) == [row.raw] }
}

/// One hover and selection vocabulary (design review 2026-10 §1.4), in a narrow window whose
/// explorer floats: the floating tree's selected and hovered rows show on its panel; in quick
/// open and the / menu the keys and the pointer move one highlight, so after ↓ and a hover only
/// the hovered row is lit and Return takes it.
final class OneHighlight: Storyline {
    override class var tags: Set<Tag> { [.files, .chat] }
    override class var variants: [Variant] { [.claude, .codex] }
    override class var needs: Needs { Needs(window: CGSize(width: 640, height: 700)) }

    static let files: [(path: String, text: String)] = [
        ("Resources/notes.txt", "notes\n"), ("Sources/App.swift", "// app\n"), ("Sources/Model.swift", "// model\n"),
        ("Sources/View.swift", "// view\n"), ("scripts/build.sh", "swift build\n"), ("README.md", "# Kore\n"),
    ]

    static var script: CLIScript {
        let commands = [
            SlashCommand(name: "compact", description: "Summarize the conversation", hint: "", kind: .command),
            SlashCommand(name: "review", description: "Review a pull request", hint: "", kind: .command),
            SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
        ]
        return CLIScript(
            start: [
                .event(.controlsLoaded(ChatControls(
                    models: [ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: ["low"])],
                    model: "haiku", effort: "low", commands: commands)))
            ],
            turns: [CLIScript.reply("OK")])
    }

    override func steps() -> [any Step] {
        let command = { (name: String) in StoryID.Composer.command(name) }
        let swift = ["Sources/App.swift", "Sources/Model.swift", "Sources/View.swift"]
        // The pointer goes to a row the keys didn't light.
        let pointed = Kept<String>()
        let unlit = Locator("a quick open row that isn't lit") { _ in
            guard let path = swift.first(where: { !litRows("quickopen").contains(StoryID.QuickOpen.row($0).raw) }) else {
                return .failure(LocatorMiss("every row lit"))
            }
            pointed.value = path
            return .success(StoryID.QuickOpen.row(path).part(.hover))
        }
        return [
            WriteFiles(Self.files), UseScript(Self.script), OpenFolder(), StartChat(),
            // The / menu: ↓ lights the second row; the pointer on another takes the light, and Return
            // picks the pointer's command.
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(.id(command("plan"))),
            Key(.down),
            onlyLit("the keys' row lit", area: "composer", command("account")),
            Press(.id(command("review").part(.hover))),
            onlyLit("only the pointer's row lit", area: "composer", command("review")),
            Snapshot("slash-menu"),
            Key(.returnKey),
            Expect("Return took the pointer's command", found: { $0.app.chat?.command?.name }) { $0.app.chat?.command?.name == "review" },
            // Quick open: the same, and Return opens the pointer's file.
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            TypeText("swift"),
            WaitForElement(.quickOpenRow("Sources/View.swift")),
            Key(.down),
            Expect("one row lit by the keys", found: { _ in litRows("quickopen").joined(separator: ", ") }) { _ in
                litRows("quickopen").count == 1
            },
            Press(unlit),
            Expect("only the pointer's row lit", found: { _ in litRows("quickopen").joined(separator: ", ") }) { _ in
                litRows("quickopen") == [StoryID.QuickOpen.row(pointed.value ?? "").raw]
            },
            Snapshot("quick-open"),
            Key(.returnKey),
            Expect.fileTabs("Return opened the pointer's row") { tabs in tabs.contains { $0.path == pointed.value && $0.active } },
            // The floating explorer: "Sources" selected, "scripts" under the pointer.
            Command(.toggleExplorer),
            WaitForElement(.treeRow("scripts")),
            RevealInTree("Sources"),
            Press(.id(StoryID.Explorer.row("scripts").part(.hover))),
            Snapshot("explorer-floating"),
        ]
    }
}

/// A value one step finds and a later one reads.
@MainActor final class Kept<Value> {
    var value: Value?
}

/// Selects a row of the tree as Reveal in Explorer does, without giving the tree the keys.
struct RevealInTree: Step {
    let path: String
    var label: String { "Reveal “\(path)” in the tree" }
    init(_ path: String) { self.path = path }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        workspace.storyRevealInTree(path)
        try await story.until("“\(path)” selected") { workspace.storyTreeSelection == path }
    }
}

/// ↑ ↓ and Return in every list (design review 2026-10 §1.7). The import picker: ↑ ↓ move a
/// highlight over its chats and Return picks the highlighted one, never importing. History: the
/// first chat lit as it opens, ↑ ↓ move the light and Return opens the lit chat. Welcome: ↑ ↓
/// light a recent folder and Return opens it.
final class ListKeys: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    /// This folder's Claude Code chats, by session id: their titles.
    static let chats = ["5e55-0001": "Check the build number.", "5e55-0002": "Tidy the tests."]
    static let welcome = "New Window"

    override func steps() -> [any Step] {
        let other = ImportFixtures.other(than: variant.provider)
        let importer = StoryID.Composer.importer
        let lit = Kept<String>()
        var steps = super.steps()
        // The import picker: two files chosen, the second picked; ↓ lights the first, Return picks it.
        steps += [
            OfferFile("first.jsonl", lines: other),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(importer)),
            OfferFile("second.jsonl", lines: other),
            Press(.id(importer.part(.choose))),
            Expect("both files listed, the second picked", found: { $0.app.chat?.storyImportRows.description }) {
                $0.app.chat?.storyImportRows == ["second.jsonl", "first.jsonl"] && $0.app.chat?.storyImportPicked == "second.jsonl"
            },
            Key(.down),
            Expect("↓ lights the row after the pick", found: { _ in litRows("composer").joined(separator: ", ") }) { story in
                guard let id = story.app.chat?.storyImportRowID("first.jsonl") else { return false }
                return litRows("composer") == [StoryID.Composer.importRow(id).raw]
            },
            Key(.returnKey),
            Expect("Return picked it, the picker still open and nothing imported", found: { $0.app.chat?.storyImportPicked }) {
                $0.app.chat?.storyImportPicked == "first.jsonl" && $0.app.chat?.storyImportOpen == true && ScriptedWorld.shared.imports.isEmpty
            },
            Key(.up),
            Expect("↑ lights the other row") { story in
                guard let id = story.app.chat?.storyImportRowID("second.jsonl") else { return false }
                return litRows("composer") == [StoryID.Composer.importRow(id).raw]
            },
            Snapshot("import-keys"),
            Key(.escape),
            ExpectElement(.id(importer), .absent),
        ]
        // History: two chats; the first lit, ↓ lights the other, Return opens it.
        steps += Self.chats.map { PutHistoryChat(session: $0.key, title: $0.value) }
        steps += [
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(StoryID.History.row("5e55-0001"))),
            WaitForElement(.id(StoryID.History.row("5e55-0002"))),
            Expect("the first chat lit", found: { _ in litRows("history").joined(separator: ", ") }) { _ in
                guard litRows("history").count == 1 else { return false }
                lit.value = litRows("history").first
                return true
            },
            Key(.down),
            Expect("↓ lights the other chat", found: { _ in litRows("history").joined(separator: ", ") }) { _ in
                guard litRows("history").count == 1, let now = litRows("history").first, now != lit.value else { return false }
                lit.value = now
                return true
            },
            Snapshot("history-keys"),
            Key(.returnKey),
            Expect("Return opened the lit chat", found: { $0.app.chat?.storyTitle }) { story in
                let session = Self.chats.keys.first { StoryID.History.row($0).raw == lit.value }
                return session.flatMap { Self.chats[$0] } == story.app.chat?.storyTitle
            },
        ]
        // Welcome: a second folder opened, so two recent ones; ↓ ↓ light the older, Return opens it.
        steps += [
            OpenAnotherFolder(),
            ShowWelcome(),
            KeyIn(Self.welcome, .down),
            Expect("↓ lights the newest folder", found: { _ in litRows("welcome").joined(separator: ", ") }) { _ in
                AppModel.shared.map { litRows("welcome") == [StoryID.Welcome.recent($0.storyRecents[0].path).raw] } ?? false
            },
            KeyIn(Self.welcome, .down),
            Expect("↓ lights the one before", found: { _ in litRows("welcome").joined(separator: ", ") }) { _ in
                guard let recents = AppModel.shared?.storyRecents, recents.count > 1 else { return false }
                lit.value = recents[1].path
                return litRows("welcome") == [StoryID.Welcome.recent(recents[1].path).raw]
            },
            KeyIn(Self.welcome, .returnKey),
            Expect("Return opened it and closed Welcome", found: { _ in AppModel.shared?.storyRecents.first?.path }) { _ in
                AppModel.shared?.storyRecents.first?.path == lit.value && !NSApp.windows.contains { $0.title == Self.welcome && $0.isVisible }
            },
        ]
        return steps
    }
}

/// ⇥ in a popup rings its buttons in turn and keeps it open (design review 2026-10 §1.7): in
/// Usage, ⇥ and ⇧⇥ move the 1pt ring and Return presses the ringed button (the extended view,
/// where ⇥ reaches its ×); in Account, Return on the ringed Sign out asks, the ring on No, go
/// back, and a second Return goes back with the ring on Sign out again.
final class PopupTab: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let usage = StoryID.Composer.usage
        let account = StoryID.Composer.account
        let row = { (name: String) in Locator.id(StoryID.Composer.command(name)) }
        let rings = { (area: String) in StoryRegistry.ids.filter { $0.hasPrefix(area + ".") && $0.hasSuffix(".focus") } }
        return [
            UseScript(UsagePopup.claude, for: "claude"), UseScript(UsagePopup.codex(.codex), for: "codex"), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(row("usage")),
            Key(.returnKey),
            WaitForElement(.id(usage.part(.extended))),
            Key(.tab),
            ExpectElement(.id(usage.part(.extended).part(.focus))),
            Expect("the popup still open") { $0.app.chat?.isUsageOpen == true },
            Key(.tab),
            Expect("⇥ moved the ring on", found: { _ in rings("composer").joined(separator: ", ") }) { _ in
                rings("composer").count == 1 && !rings("composer").contains(usage.part(.extended).part(.focus).raw)
            },
            Snapshot("usage-tab"),
            Key(KeyChord(.tab, .shift)),
            ExpectElement(.id(usage.part(.extended).part(.focus))),
            Expect("the popup still open, the draft untouched") { $0.app.chat?.isUsageOpen == true && $0.app.chat?.draft == "" },
            Key(.returnKey),
            WaitForElement(.id(StoryID.UsageModal.card)),
            TabTo(StoryID.UsageModal.card.part(.close)),
            Snapshot("usage-extended-tab"),
            Key(.returnKey),
            ExpectElement(.id(StoryID.UsageModal.card), .absent),
            // Account.
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            Press(row("account")),
            WaitForElement(.id(account.part(.signOut))),
            Key(.tab),
            ExpectElement(.id(account.part(.switch).part(.focus))),
            TabTo(account.part(.signOut)),
            Key(.returnKey),
            WaitForElement(.id(account.part(.allow))),
            ExpectElement(.id(account.part(.cancel).part(.focus))),
            FadesEnd(),
            Snapshot("account-tab"),
            Key(.returnKey),
            ExpectElement(.id(account.part(.allow)), .absent),
            ExpectElement(.id(account.part(.signOut).part(.focus))),
            Expect("still signed in, the popup open") { story in
                story.app.chat?.isAccountOpen == true && !ScriptedAccounts.shared.log.contains(.signOut(story.variant?.provider ?? ""))
            },
            Key(.escape),
            ExpectElement(.id(account), .absent),
        ]
    }
}

/// ⇥ until a button has the ring, a few times at most, each time waiting for the ring to move.
struct TabTo: Step {
    let id: StoryID
    var label: String { "⇥ to \(id)" }
    init(_ id: StoryID) { self.id = id }

    func run(_ story: StoryContext) async throws {
        let ring = { StoryRegistry.ids.first { $0.hasSuffix(".focus") } }
        for _ in 0..<8 {
            if StoryRegistry.entry(id.part(.focus).raw) != nil { return }
            let before = ring()
            try await story.input.key(.tab)
            try? await story.until("the ring to move", timeout: .seconds(2)) { ring() != nil && ring() != before }
        }
        if StoryRegistry.entry(id.part(.focus).raw) == nil {
            throw StoryFailure.expectation("the ring on \(id) within 8 ⇥ (it's on \(ring() ?? "nothing"))")
        }
    }
}

/// A Claude Code chat in this folder's store, for History and the import picker to list.
struct PutHistoryChat: Step {
    let session: String
    let title: String
    var label: String { "Put the Claude Code chat “\(title)” in the folder" }

    func run(_ story: StoryContext) async throws {
        let file = ClaudeHistory.transcript(sessionId: session, in: story.folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = ImportFixtures.claude.map {
            $0.replacingOccurrences(of: "/tmp/source", with: story.folder.path).replacingOccurrences(of: "5e55-0001", with: session)
                .replacingOccurrences(of: "Check the build number.", with: title)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A second folder opened in its own window, so Welcome lists two recent folders.
struct OpenAnotherFolder: Step {
    var label: String { "Open another folder" }
    var timeout: Duration? { .seconds(15) }

    func run(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        let folder = story.outputs.appendingPathComponent("another", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        try await story.until("the folder among the recent ones") {
            model.storyRecents.first?.lastPathComponent == "another"
        }
    }
}

/// The Welcome window, as Window ▸ Welcome Window shows it.
struct ShowWelcome: Step {
    var label: String { "Show the Welcome window" }

    func run(_ story: StoryContext) async throws {
        AppModel.shared?.storyShowWelcome()
        try await story.until("the Welcome window with its recent folders") {
            NSApp.windows.contains { $0.title == ListKeys.welcome && $0.isVisible } && StoryRegistry.ids.contains { $0.hasPrefix("welcome.recent") }
        }
        // Its view has appeared, and with it the keys' monitor: a key the monitor sees comes back.
        try await story.until("Welcome taking keys") { AppModel.shared?.welcomeTakesKeys == true }
    }
}


/// Right-clicking Kore in the Dock offers New Window, which brings up Welcome (a folder, or a
/// recent one, opens its window from there).
final class DockMenuNewWindow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Expect("the Dock menu offers New Window", found: { _ in AppModel.shared?.storyDockMenu.description }) { _ in
                AppModel.shared?.storyDockMenu == ["New Window"]
            },
            Do("Pick New Window") { _ in AppModel.shared?.storyPickDockItem("New Window") },
            Expect("the Welcome window shown") { _ in
                NSApp.windows.contains { $0.title == ListKeys.welcome && $0.isVisible }
            },
        ]
    }
}

/// Waits out a row's fade (`Motion.fade`), so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
