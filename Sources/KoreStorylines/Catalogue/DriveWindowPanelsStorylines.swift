import AppKit
import Foundation
import KoreCore
import KoreLink
import KoreUI
import src

// The folder window's own controls that no other storyline uses as a person does: the space
// beside Go to File and beside a floating explorer, History's Rename, Archive and archived view,
// the ask before moving a working chat, the import picker's search, Sign in and Try again, Return
// on a link's card, the install card's ⌄, Locate…, Cancel and Copy command, the resume cue's
// list, a group's close question's Cancel, the terminal sash's double click, a tab's × and its
// Stop, and dragging a tab group by its chip.

/// A turn that runs until it's stopped.
private let drivePanelsHold: [Beat] = [.startTurn, .tool(name: "Bash", detail: "sleep 600", wait: .interrupt)]

// MARK: - Clicks beside a panel

/// Go to File open: a click beside it closes it.
final class DriveWindowQuickOpenOutside: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("Sources/App.swift", "let app = 1\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.goToFile),
            WaitForFocus(.id(StoryID.QuickOpen.field)),
            Expect("Go to File open") { $0.app.workspace?.storyQuickOpenShown == true },
            Press(.id(StoryID.QuickOpen.outside)),
            Expect("closed by the click beside it") { $0.app.workspace?.storyQuickOpenShown == false },
            ExpectElement(.id(StoryID.QuickOpen.field), .absent),
        ]
    }
}

/// A window narrower than 700 pt: the explorer floats over it, and a press beside it closes it.
final class DriveWindowExplorerOutside: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var needs: Needs { Needs(window: CGSize(width: 620, height: 700)) }
    override class var files: [(path: String, text: String)] { [("notes.md", "# Notes\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            // A run's --size is wider: the explorer floats only in a narrow window.
            SizeWindow(width: 620),
            Command(.toggleExplorer),
            WaitForElement(.treeRow("notes.md")),
            Expect("the explorer floating over the window") { story in
                story.app.workspace?.explorerOpen == true && StoryElement(StoryID.Explorer.outside) != nil
            },
            DriveWindowClickNear(.id(StoryID.Explorer.outside), x: 0.92, y: 0.5),
            Expect("closed by the press beside it") { $0.app.workspace?.explorerOpen == false },
            ExpectElement(.treeRow("notes.md"), .absent),
        ]
    }
}

// MARK: - History

/// History's pencil on a lit row: the name in a field, Return renames the chat; again, Esc
/// leaves the name as it was.
final class DriveWindowHistoryRename: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let session = "d71e-0001"

    @MainActor private static func title(_ story: StoryContext) -> String? {
        story.app.workspace?.storyHistory.first { $0.id == session }?.title
    }

    override func steps() -> [any Step] {
        let row = StoryID.History.row(Self.session)
        let pencil = StoryID.History.rename(Self.session)
        return super.steps() + [
            PutHistoryChat(session: Self.session, title: "Rename me"),
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(row)),
            Press(.id(row.part(.hover))),
            Press(.id(pencil)),
            WaitForFocus(.id(pencil.part(.field))),
            Key(.cmd("a")), TypeText("Renamed in History"), Key(.returnKey),
            Expect("the chat renamed", found: { Self.title($0) }) { Self.title($0) == "Renamed in History" },
            ExpectElement(.id(pencil.part(.field)), .absent),
            Press(.id(row.part(.hover))),
            Press(.id(pencil)),
            WaitForFocus(.id(pencil.part(.field))),
            TypeText(" not this"),
            Expect("“ not this” in the field", found: { story in (story.window?.firstResponder as? NSTextView)?.string }) { story in
                (story.window?.firstResponder as? NSTextView)?.string.hasSuffix(" not this") == true
            },
            Key(.escape),
            ExpectElement(.id(pencil.part(.field)), .absent),
            Expect("Esc kept the name", found: { Self.title($0) }) { Self.title($0) == "Renamed in History" },
        ]
    }
}

/// History's Archive on a lit row: the chat leaves the list; the archive button shows the
/// archived chats, and Unarchive there brings it back and opens it.
final class DriveWindowHistoryArchive: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let session = "d71e-0002"

    override func steps() -> [any Step] {
        let row = StoryID.History.row(Self.session)
        return super.steps() + [
            PutHistoryChat(session: Self.session, title: "Archive me"),
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(row)),
            Press(.id(row.part(.hover))),
            Press(.id(row.part(.archive))),
            Expect("archived") { $0.app.workspace?.storyArchivedHistory.contains(Self.session) == true },
            ExpectElement(.id(row), .absent),
            Press(.id(StoryID.History.archived)),
            WaitForElement(.id(row)),
            Press(.id(row.part(.hover))),
            Press(.id(row.part(.archive))),
            Expect("back from the archive, opened in a tab", found: { story in story.app.workspace.map { "\($0.tabs.map(\.title)), archived \($0.storyArchivedHistory)" } }) { story in
                guard let workspace = story.app.workspace else { return false }
                return !workspace.storyArchivedHistory.contains(Self.session)
                    && workspace.tabs.contains { $0.chat?.sessionId == Self.session || $0.title == "Archive me" }
            },
        ]
    }
}

/// A working chat cut from History and pasted into another folder's window: that window asks
/// first. Cancel leaves the chat working where it is; "Stop and move" stops it and its tab here
/// closes.
final class DriveWindowChatPaste: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [drivePanelsHold]) }

    override func steps() -> [any Step] {
        let kept = DriveWindowPasteKept()
        let row = Locator("the working chat's History row") { _ in
            kept.session.map { .success(StoryID.History.row($0)) } ?? .failure(LocatorMiss("no session noted yet", pending: true))
        }
        let working: @MainActor (StoryContext) -> Bool = { story in
            story.app.workspace?.tabs.first { $0.id == kept.tab }?.chat?.isWorking == true
        }
        return super.steps() + [
            Send("Keep working"),
            Expect("the chat working, its session known") { try $0.activeChat().isWorking && $0.activeChat().sessionId != nil },
            Do("The CLI lists the chat, as a real one lists its own") { story in
                _ = story.stash(DriveWindowPasteKept.self) { kept }
                let chat = try story.activeChat()
                guard let id = chat.sessionId else { throw StoryFailure.modelMissing("the chat's session") }
                ScriptedWorld.shared.list(id, provider: chat.provider.id, folder: story.folder, title: "Moving chat")
                kept.session = id
                kept.tab = story.app.workspace?.activeTab.id
            },
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(row, timeout: .seconds(10)),
            RightClick(row),
            DriveWindowOption("Cut"),
            OpenAnotherFolder(),
            DriveWindowPasteThere(),
            WaitForElement(.id(StoryID.History.paste.part(.cancel))),
            ExpectElement(.id(StoryID.History.paste.part(.use))),
            Press(.id(StoryID.History.paste.part(.cancel))),
            ExpectElement(.id(StoryID.History.paste.part(.cancel)), .absent),
            Expect("Cancel: the chat still working here") { working($0) },
            DriveWindowPasteThere(),
            WaitForElement(.id(StoryID.History.paste.part(.use))),
            Press(.id(StoryID.History.paste.part(.use))),
            ExpectElement(.id(StoryID.History.paste.part(.use)), .absent),
            Expect("Stop and move: the chat's tab here closed", timeout: .seconds(10)) { story in
                story.app.workspace?.tabs.contains { $0.id == kept.tab } == false
            },
        ]
    }
}

/// The chat being moved, and the other window, closed when the storyline ends.
@MainActor
private final class DriveWindowPasteKept: StoryFinishing {
    var session: String?
    var tab: UUID?

    static var other: Workspace? {
        Workspace.all.allObjects.first { !$0.isClosed && $0.folder.lastPathComponent == "another" }
    }

    func finish() { Self.other?.window?.close() }
}

/// The other folder's window: its + right-clicked, Paste Chat picked.
private struct DriveWindowPasteThere: Step {
    var label: String { "Right-click the other window's +, Paste Chat" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let window = try await story.wait("the other folder's window") { DriveWindowPasteKept.other?.window }
        let plus = try await story.wait("its +") { StoryElement(StoryID.Titlebar.newtab, in: window) }
        try await story.input.rightClick(plus)
        try await DriveWindowOption("Paste Chat").run(story)
    }
}

// MARK: - Import

/// The import picker's search: typing narrows the rows to the chats it names; cleared, both
/// show again.
final class DriveWindowImportSearch: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let other = ImportFixtures.other(than: variant.provider)
        let importer = StoryID.Composer.importer
        // The list has a search field past eight chats.
        var more: [any Step] = []
        for n: Int in 2...9 {
            more.append(OfferFile("file\(n).jsonl", lines: other))
            more.append(Press(.id(importer.part(.choose))))
            more.append(Expect("\(n) files listed", found: { $0.app.chat?.storyImportRows.description }) { $0.app.chat?.storyImportRows.count == n })
        }
        return super.steps() + [
            OfferFile("first.jsonl", lines: other),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(importer), timeout: .seconds(20)),
        ] + more + [
            Click(.id(importer.part(.field))),
            WaitForFocus(.id(importer.part(.field))),
            TypeText("first"),
            Expect("only the chat it names", found: { $0.app.chat?.storyImportRows.description }) {
                $0.app.chat?.storyImportRows == ["first.jsonl"]
            },
            TypeText("zz"),
            Expect("none match", found: { $0.app.chat?.storyImportRows.description }) { $0.app.chat?.storyImportRows.isEmpty == true },
            Key(.cmd("a")), Key(KeyChord(.backspace)),
            Expect("all again", found: { $0.app.chat?.storyImportRows.description }) { $0.app.chat?.storyImportRows.count == 9 },
        ]
    }
}

/// The chat's CLI signed out: the picked chat's line says so, with Sign in; Sign in starts the
/// CLI's sign-in in Account, its page opened.
final class DriveWindowImportSignIn: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        let product = Registry.provider(provider)?.usage.product ?? provider
        let accounts = ScriptedAccounts.shared
        let importer = StoryID.Composer.importer
        return [
            BoxStep("The CLI signed out") { _ in
                accounts.status[provider] = codex ? ["account": nil, "requiresOpenaiAuth": true] : ["loggedIn": false, "authMethod": "none"]
                await AccountStore.shared.refresh(provider)
            },
        ] + super.steps() + [
            OfferFile("source.jsonl", lines: ImportFixtures.other(than: provider)),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(importer), timeout: .seconds(20)),
            Expect("the pick says the CLI isn't signed in", found: { $0.app.chat?.storyImportLine }) {
                $0.app.chat?.storyImportLine == "\(product) isn't signed in."
            },
            Press(.id(importer.part(.signIn))),
            WaitForElement(.id(StoryID.Composer.account)),
            Expect("the sign-in under way, its page opened", found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) { story in
                story.app.chat?.storyAccount == ["Waiting for the browser…"] && accounts.log.contains(.opened(codex ? "auth.openai.com" : "claude.com"))
            },
            // The browser's row settled: its Cancel past its Copy link (the starting row's Cancel,
            // fading out, stood where Copy link is now).
            Expect("the row's Cancel past its Copy link") { story in
                guard let window = story.window, let cancel = StoryElement(StoryID.Composer.account.part(.cancel), in: window)?.frame,
                    let copy = StoryElement(StoryID.Composer.account.part(.copy), in: window)?.frame else { return false }
                return cancel.minX >= copy.maxX
            },
            Press(.id(StoryID.Composer.account.part(.cancel))),
            Expect("Cancel: the sign-in ended, its Cancel gone", found: { story in
                "\(story.app.chat?.storyAccount ?? []); \(InputDriver.lastRoute)"
            }) { story in
                story.window.map { StoryElement(StoryID.Composer.account.part(.cancel), in: $0) == nil } ?? false
            },
        ]
    }
}

/// An import that fails (the folder moved away as it ran) says why, with Try again; with the
/// folder back, Try again reads the pick again and it's ready to import.
final class DriveWindowImportRetry: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let importer = StoryID.Composer.importer
        let moved = DriveWindowFolderAway()
        return super.steps() + [
            OfferFile("source.jsonl", lines: ImportFixtures.other(than: variant.provider)),
            Press(.id(StoryID.Composer.importLine)),
            WaitForElement(.id(importer), timeout: .seconds(20)),
            Expect("the file picked, ready", found: { $0.app.chat?.storyImportLine }) { $0.app.chat?.storyImportReady == true },
            Do("The folder moved away") { story in
                _ = story.stash(DriveWindowFolderAway.self) { moved }
                try moved.away(story.folder)
            },
            Press(.id(importer.part(.add))),
            Expect("the import failed, saying so", found: { $0.app.chat?.storyImportLine }) {
                $0.app.chat?.storyImportLine.hasPrefix("Couldn't import") == true
            },
            WaitForElement(.id(importer.part(.reload))),
            Do("The folder back") { _ in try moved.back() },
            Press(.id(importer.part(.reload))),
            Expect("read again: ready to import", found: { $0.app.chat?.storyImportLine }) { $0.app.chat?.storyImportReady == true },
            ExpectElement(.id(importer.part(.reload)), .absent),
        ]
    }
}

/// The storyline's folder moved aside, and back (when the storyline ends, at the latest).
@MainActor
private final class DriveWindowFolderAway: StoryFinishing {
    private var folder: URL?

    private func aside(_ folder: URL) -> URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-away") }

    func away(_ folder: URL) throws {
        try FileManager.default.moveItem(at: folder, to: aside(folder))
        self.folder = folder
    }

    func back() throws {
        guard let folder else { return }
        try FileManager.default.moveItem(at: aside(folder), to: folder)
        self.folder = nil
    }

    func finish() { try? back() }
}

// MARK: - A link's card

// MARK: - Installing a CLI

/// The install card: Cancel closes it, nothing installed.
final class DriveWindowInstallCancel: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let card = StoryID.NewTab.install
        return [
            DriveWindowFakeMac(provider, installer: DriveWindowFakeMac.succeeds),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            DriveWindowFakeMac.readStatus(provider),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            Press(.id(StoryID.NewTab.provider(provider))),
            WaitForElement(.id(card)),
            Expect("the card offering to install") { _ in CLIInstalls.shared.storyState == "offer" },
            Press(.id(card.part(.cancel))),
            Expect("the card closed, nothing installed") { _ in CLIInstalls.shared.storyState == nil },
            ExpectElement(.id(card), .absent),
            ExpectElement(.id(StoryID.NewTab.missing(provider))),
        ]
    }
}

/// A failed install's Copy command puts the installer's command on the clipboard, to run in a
/// terminal.
final class DriveWindowInstallCopy: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "codex"
        let card = StoryID.NewTab.install
        let command = CLIInstaller.command(.official, for: provider) ?? ""
        return [
            DriveWindowFakeMac(provider, installer: DriveWindowFakeMac.offline),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            DriveWindowFakeMac.readStatus(provider),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            Press(.id(StoryID.NewTab.provider(provider))),
            Press(.id(card.part(.install))),
            WaitForElement(.id(card.part(.copy)), timeout: .seconds(15)),
            Do("An empty clipboard") { _ in TranscriptSelection.pasteboard.clearContents() },
            Press(.id(card.part(.copy))),
            Expect("the installer's command copied", found: { _ in TranscriptSelection.pasteboard.string(forType: .string) }) { _ in
                !command.isEmpty && TranscriptSelection.pasteboard.string(forType: .string) == command
            },
        ]
    }
}

/// Locate…: a binary picked by hand that answers becomes the CLI's; the card closes and the
/// not-installed mark goes.
final class DriveWindowInstallLocate: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let card = StoryID.NewTab.install
        let fake = DriveWindowFakeMac(provider, installer: DriveWindowFakeMac.succeeds, picks: true)
        return [
            fake,
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            DriveWindowFakeMac.readStatus(provider),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            Press(.id(StoryID.NewTab.provider(provider))),
            WaitForElement(.id(card.part(.locate))),
            Do("A binary of the CLI made by hand, the one the panel gives") { _ in
                let binary = try DriveWindowFakeMac.makeBinary(provider)
                ScriptedAccounts.shared.chosenFile = binary
            },
            Press(.id(card.part(.locate))),
            Expect("the card closed", timeout: .seconds(10), found: { _ in CLIInstalls.shared.storyState }) { _ in CLIInstalls.shared.storyState == nil },
            ExpectElement(.id(StoryID.NewTab.missing(provider)), .absent, timeout: .seconds(10)),
        ]
    }
}

/// Install's ⌄, on a Mac with Homebrew or npm: the ways listed, the official one ticked; picking
/// it installs that way.
final class DriveWindowInstallMethod: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "codex"
        let card = StoryID.NewTab.install
        return [
            DriveWindowFakeMac(provider, installer: DriveWindowFakeMac.succeeds),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            DriveWindowFakeMac.readStatus(provider),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            Press(.id(StoryID.NewTab.provider(provider))),
            WaitForElement(.id(card)),
            DriveWindowNeedsMethods(),
            Press(.id(card.part(.method))),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("the ways listed, the official installer first", found: { _ in "\(StoryMenus.open)" }) { _ in
                StoryMenus.open.first == "Official installer" && StoryMenus.open.count > 1
            },
            DriveWindowOption("Official installer"),
            Expect("installing", found: { _ in CLIInstalls.shared.storyState }) { _ in
                CLIInstalls.shared.storyState?.hasPrefix("installing") == true || CLIInstalls.shared.storyState == "installed"
            },
            WaitForElement(.id(card.part(.done)), timeout: .seconds(20)),
        ]
    }
}

/// The ⌄ shows only where the Mac has another way to install (Homebrew or npm); without one,
/// the rest of the storyline is skipped.
private struct DriveWindowNeedsMethods: Step {
    var label: String { "Install's ⌄, where this Mac has Homebrew or npm" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        do {
            try await story.until("Install's ⌄", timeout: .seconds(5)) { StoryElement(StoryID.NewTab.install.part(.method)) != nil }
        } catch StoryFailure.timedOut {
            throw StorySkip("this Mac has neither Homebrew nor npm, so Install has no ⌄")
        }
    }
}

/// A Mac of the storyline's own: Kore's lookup searches only a fresh HOME (nothing installed),
/// the installer a script; with `picks`, the binary Locate… is given is on the lookup's list.
private struct DriveWindowFakeMac: Step {
    let provider: String
    let installer: String
    var picks = false
    var label: String { "A Mac without \(provider), its installer a fake" }

    init(_ provider: String, installer: String, picks: Bool = false) {
        self.provider = provider
        self.installer = installer
        self.picks = picks
    }

    func run(_ story: StoryContext) async throws {
        guard case .scripted = story.flags.cli else { throw StoryFailure.other("the install storylines need --cli scripted") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kore-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let chosen = picks ? Self.binary(provider) : nil
        if let chosen { try? FileManager.default.removeItem(at: chosen) }
        CLIExecutable.look(in: CLILocator.Places(home: home, path: [], chosen: chosen, system: [], applications: []))
        CLIInstaller.standIn.value = .init(script: try Self.script(installer), environment: ["HOME": home.path])
        ScriptedAccounts.shared.lookup.insert(provider)
        story.stash(DriveWindowFakeMacReset.self) { DriveWindowFakeMacReset() }.provider = provider
    }

    static func readStatus(_ provider: String) -> Do {
        Do("Kore reads the CLI's status, as at launch") { _ in Task { await AccountStore.shared.refresh(provider) } }
    }

    /// Where Locate…'s binary is made.
    static func binary(_ provider: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kore-locate-\(provider)", isDirectory: true).appendingPathComponent(provider)
    }

    /// A binary that answers `--version`.
    static func makeBinary(_ provider: String) throws -> URL {
        let file = binary(provider)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"1.0.0 (picked)\"\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    static func script(_ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kore-drive-installer-\(abs(text.hashValue)).sh")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static let succeeds = """
        echo "Setting up $1"
        sleep 0.2
        echo "Downloading $1 · 9 of 29 MB"
        sleep 0.2
        echo "Installing to $HOME/.local/bin"
        mkdir -p "$HOME/.local/bin"
        printf '#!/bin/sh\\necho "1.0.0 (fake)"\\n' > "$HOME/.local/bin/$1"
        chmod +x "$HOME/.local/bin/$1"
        echo "Installed successfully"
        """

    static let offline = """
        echo "Downloading $1"
        sleep 0.2
        echo "curl: (6) Could not resolve host: downloads.example" >&2
        exit 6
        """
}

/// Locate…'s pick forgotten when the storyline ends.
@MainActor
private final class DriveWindowFakeMacReset: StoryFinishing {
    var provider = ""
    func finish() { if !provider.isEmpty { CLIExecutable.choose(provider, nil) } }
}

// MARK: - Resume after a close

/// The resume cue's line opens its list, a tick per chat; unticking one and picking Resume
/// sends only the ticked chat its note.
final class DriveWindowResumeList: WorkResumeStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        setUp(helper: true) + [
            WaitForElement(.id(StoryID.Titlebar.resume.part(.title))),
            Press(.id(StoryID.Titlebar.resume.part(.title))),
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("a row per chat, then Resume with sub-agents", found: { _ in "\(StoryMenus.open)" }) { _ in
                StoryMenus.open.count == 4 && StoryMenus.open.last == "Resume with sub-agents"
            },
            Press(.id(StoryID.Options.item(1))),
            Expect("the second chat unticked: Resume, one chat", found: { story in try? Self.workspace(story).resumeOffer.map { "\($0.picked) \($0.action)" } }) { story in
                let offer = try Self.workspace(story).resumeOffer
                return offer?.picked == 1 && offer?.action == "Resume"
            },
            WaitForElement(.id(StoryID.Options.panel)),
            DriveWindowOption("Resume"),
            Expect("only the ticked chat sent its note", found: { story in "\((try? Self.sent(story, tab: 0)) ?? []) \((try? Self.sent(story, tab: 1)) ?? [])" }) { story in
                try Self.sent(story, tab: 0) == [Workspace.resumeText(agents: 0, commands: 0)] && Self.sent(story, tab: 1).isEmpty
            },
            ExpectElement(.id(StoryID.Titlebar.resume), .absent),
        ]
    }
}

// MARK: - Tabs and groups

/// A group's close asks while a chat in it works: Cancel leaves both tabs, the group and the
/// turn as they were.
final class DriveWindowGroupCloseCancel: TabGroupStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { CLIScript(turns: [[.startTurn, .wait(.interrupt), .finishTurn(.interrupted)]]) }

    override func steps() -> [any Step] {
        [UseScript(Self.script), OpenFolder(), StartChat()] + [
            Send("keep going"),
            Expect("the first chat's turn running") { try $0.activeChat().isRunning },
            OpenTabs(3),
            TabGroupProbe.make(1, onto: 0),
            RightClickChip(),
            ExpectElement(.id(StoryID.TabGroups.popup), .visible),
            Press(.id(StoryID.TabGroups.close)),
            ExpectElement(.id(StoryID.TabGroups.stopAndClose), .visible),
            Press(.id(StoryID.TabGroups.close.part(.cancel))),
            ExpectElement(.id(StoryID.TabGroups.stopAndClose), .absent),
            Expect("all four tabs, the group and the turn kept") { story in
                let workspace = try TabGroupProbe.workspace(story)
                return workspace.tabs.count == 4 && workspace.tabGroups.groups.count == 1
                    && workspace.tabs.first?.chat?.isRunning == true
            },
        ]
    }
}

/// A group dragged by its chip past the last tab: its tabs move there together.
final class DriveWindowGroupDrag: TabGroupStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        super.steps() + [
            TabGroupProbe.make(1, onto: 0),
            Expect("tabs 1 and 2 grouped") { try TabGroupProbe.members($0) == [0, 1] },
            DriveWindowDragChip(),
            Expect("the group's tabs last, side by side", found: { "\((try? TabGroupProbe.members($0)) ?? [])" }) {
                try TabGroupProbe.members($0) == [2, 3]
            },
        ]
    }
}

/// The group's chip pressed and dragged to the strip's last tab's far edge.
private struct DriveWindowDragChip: Step {
    var label: String { "Drag the group's chip past the last tab" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let workspace = try TabGroupProbe.workspace(story)
        let group = try TabGroupProbe.group(story)
        let chip = try await story.element(.id(StoryID.TabGroups.chip(group.id)))
        guard let last = workspace.tabs.last else { throw StoryFailure.modelMissing("a last tab") }
        let end = try await story.element(.id(StoryID.Tabs.tab(last.id)))
        guard let window = chip.window, let from = chip.frame, let to = end.frame else { throw StoryFailure.modelMissing("the chip's and the last tab's frames") }
        await story.input.drag(from: CGPoint(x: from.midX, y: from.midY), to: CGPoint(x: to.maxX - 2, y: from.midY), in: window, steps: 16)
        try await story.idle()
    }
}

/// A tab's ×: an idle chat's tab closes at once; a running chat's asks in the tab, and its Stop
/// closes it.
final class DriveWindowTabClose: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { CLIScript(turns: [drivePanelsHold]) }

    private final class Running { var id: UUID? }

    override func steps() -> [any Step] {
        let running = Running()
        let tab = { (part: StoryID.Part) in
            Locator("the running chat's tab › \(part.rawValue)") { _ in
                running.id.map { .success(StoryID.Tabs.tab($0).part(part)) } ?? .failure(LocatorMiss("no running chat yet"))
            }
        }
        return super.steps() + [
            Send("Run the long job"),
            Expect("the turn running") { story in
                running.id = story.app.workspace?.activeTab.id
                return try story.activeChat().isRunning
            },
            OpenTabs(2),
            Expect("three tabs") { $0.app.workspace?.tabs.count == 3 },
            Press(Locator.tab(3).action(.close)),
            Expect("the idle tab closed at once") { $0.app.workspace?.tabs.count == 2 },
            Press(tab(.close)),
            WaitForElement(tab(.allow)),
            Expect("still both tabs, the turn running") { story in
                story.app.workspace?.tabs.count == 2 && story.app.workspace?.tabs.first { $0.id == running.id }?.chat?.isRunning == true
            },
            Press(tab(.allow)),
            Expect("Stop closed the running chat's tab") { story in
                story.app.workspace?.tabs.count == 1 && story.app.workspace?.tabs.contains { $0.id == running.id } == false
            },
        ]
    }
}

// MARK: - The terminal

/// The terminal's sash dragged up grows it; a double click on the sash puts its height back.
final class DriveWindowTerminalSash: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    private final class Height { var value: CGFloat = 0 }

    override func steps() -> [any Step] {
        let height = Height()
        return super.steps() + [
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
            Key(.ctrl("`")),
            ExpectElement(.id(StoryID.Terminal.panel), .visible),
            Expect("the terminal at its own height") { story in
                height.value = story.app.workspace?.storyTerminalHeight ?? 0
                return height.value > 0
            },
            DriveWindowDragSash(),
            Expect("taller", found: { "\($0.app.workspace?.storyTerminalHeight ?? 0)" }) { ($0.app.workspace?.storyTerminalHeight ?? 0) > height.value + 40 },
            DoubleClick(.id(StoryID.Terminal.sash)),
            Expect("back to its own height", found: { "\($0.app.workspace?.storyTerminalHeight ?? 0) of \(height.value)" }) { story in
                abs((story.app.workspace?.storyTerminalHeight ?? 0) - height.value) < 1 && story.app.workspace?.storyTerminalMaximized == false
            },
        ]
    }
}

/// The terminal's sash pressed and moved up 80 pt.
private struct DriveWindowDragSash: Step {
    var label: String { "Drag the terminal's sash up" }

    func run(_ story: StoryContext) async throws {
        let sash = try await story.element(.id(StoryID.Terminal.sash))
        guard let frame = sash.frame, let window = story.window else { throw StoryFailure.other("no terminal sash") }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        await story.input.drag(from: start, to: CGPoint(x: start.x, y: start.y + 80), in: window)
        try await story.idle()
    }
}

// MARK: - Shared

/// A click at a spot inside an element, by fractions of its frame (0…1 from its left and its
/// bottom): beside whatever sits in its middle.
struct DriveWindowClickNear: Step {
    let target: Locator
    let x: CGFloat
    let y: CGFloat
    var label: String { "Click \(target) at \(Int(x * 100))% across" }
    init(_ target: Locator, x: CGFloat, y: CGFloat) {
        self.target = target
        self.x = x
        self.y = y
    }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let window = element.window, let frame = element.frame else { throw StoryFailure.modelMissing("\(target)'s frame") }
        await story.input.click(at: CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y), in: window)
        try await story.idle()
    }
}
