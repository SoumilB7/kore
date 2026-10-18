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
