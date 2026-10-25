import Foundation
import KoreCore
import KoreUI

/// A Mac without the variant's CLI (cli-install.html): New tab's bar shows its not-installed
/// mark; a click grows the bar into the install card; Install runs the installer (here a fake
/// one, in a HOME of its own) with its stages and size along the bar's top edge; "✓ … installed"
/// shows, the bar folds back without the mark, and the CLI starts a chat. Kore finds the new
/// binary by its own lookup, with no restart.
final class InstallMissingCLI: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let other = provider == "claude" ? "codex" : "claude"
        let card = StoryID.NewTab.install
        return [
            FakeMac(provider, installer: FakeMac.succeeds),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            FakeMac.readStatus(provider, other),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            ExpectElement(.id(StoryID.NewTab.missing(other)), .absent),
            ExpectElement(.id(card), .absent),
            Snapshot("install-missing"),
            // The click grows the bar into the card.
            Press(.id(StoryID.NewTab.provider(provider))),
            WaitForElement(.id(card)),
            Expect("the card offering to install", found: { _ in CLIInstalls.shared.storyState }) { _ in CLIInstalls.shared.storyState == "offer" },
            ExpectElement(.id(card.part(.locate))),
            ExpectElement(.id(card.part(.cancel))),
            Expect("no chat started") { $0.app.chat == nil },
            Snapshot("install-card"),
            // Install: the stages and the size, the line along the top edge.
            Press(.id(card.part(.install))),
            WaitForElement(.id(card.part(.working))),
            Expect("the download's size in the stage line", found: { _ in CLIInstalls.shared.storyState }) { _ in
                guard let line = CLIInstalls.shared.storyState else { return false }
                return line.hasPrefix("installing: Downloading · ") && line.hasSuffix(" of 29 MB")
            },
            Snapshot("install-progress"),
            // Installed: said for a moment, the mark gone, then the bar folds back.
            WaitForElement(.id(card.part(.done)), timeout: .seconds(20)),
            ExpectElement(.id(StoryID.NewTab.missing(provider)), .absent),
            ExpectElement(.id(card.part(.working)), .absent),
            Snapshot("install-done"),
            ExpectElement(.id(card), .absent, timeout: .seconds(5)),
            // The CLI is usable: its chat starts from the same bar.
            Press(.id(StoryID.NewTab.provider(provider))),
            Expect("a \(provider) chat started", found: { $0.app.chat?.providerID }) { $0.app.chat?.providerID == provider },
        ]
    }
}

/// The install fails offline: the card says "Couldn't install …" with one reason (never the
/// installer's words), Try again and Copy command; with the network back, Try again installs.
final class InstallFailsOffline: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let other = provider == "claude" ? "codex" : "claude"
        let card = StoryID.NewTab.install
        return [
            FakeMac(provider, installer: FakeMac.offline),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])),
            OpenFolder(),
            FakeMac.readStatus(provider, other),
            WaitForElement(.id(StoryID.NewTab.missing(provider))),
            Press(.id(StoryID.NewTab.provider(provider))),
            Press(.id(card.part(.install))),
            WaitForElement(.id(card.part(.retry)), timeout: .seconds(15)),
            Expect("one reason: offline", found: { _ in CLIInstalls.shared.storyState }) { _ in CLIInstalls.shared.storyState == "failed: No internet connection." },
            ExpectElement(.id(card.part(.copy))),
            ExpectElement(.id(card.part(.working)), .absent),
            ExpectElement(.id(StoryID.NewTab.missing(provider))),
            Snapshot("install-failed"),
            // The network is back: Try again installs.
            Do("the network back") { _ in CLIInstaller.standIn.value?.script = try FakeMac.script(FakeMac.succeeds) },
            Press(.id(card.part(.retry))),
            WaitForElement(.id(card.part(.done)), timeout: .seconds(20)),
            ExpectElement(.id(StoryID.NewTab.missing(provider)), .absent),
        ]
    }
}

/// A Mac of the storyline's own: Kore's lookup searches only a fresh HOME (nothing installed),
/// the installer is a script that prints stages and puts a binary answering `--version` in its
/// `~/.local/bin`, and the scripted status reads fail while that binary isn't there.
private struct FakeMac: Step {
    let provider: String
    let installer: String
    var label: String { "A Mac without \(provider), its installer a fake" }
    var timeout: Duration? { nil }

    init(_ provider: String, installer: String) {
        self.provider = provider
        self.installer = installer
    }

    func run(_ story: StoryContext) async throws {
        guard case .scripted = story.flags.cli else { throw StoryFailure.other("the install storylines need --cli scripted") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kore-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        CLIExecutable.look(in: CLILocator.Places(home: home, path: [], system: [], applications: []))
        CLIInstaller.standIn.value = .init(script: try Self.script(installer), environment: ["HOME": home.path])
        ScriptedAccounts.shared.lookup.insert(provider)
    }

    /// Kore's status read of both CLIs, as at launch.
    static func readStatus(_ providers: String...) -> Do {
        Do("Kore reads the CLIs' status, as at launch") { _ in
            for provider in providers { Task { await AccountStore.shared.refresh(provider) } }
        }
    }

    /// The script's file, written once a run.
    static func script(_ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kore-installer-\(abs(text.hashValue)).sh")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static let succeeds = """
        echo "Setting up $1"
        sleep 0.4
        echo "Downloading $1 · 9 of 29 MB"
        sleep 0.8
        echo "Downloading $1 · 18 of 29 MB"
        sleep 1.2
        echo "Verifying checksum"
        sleep 0.3
        echo "Installing to $HOME/.local/bin"
        mkdir -p "$HOME/.local/bin"
        printf '#!/bin/sh\\necho "1.0.0 (fake)"\\n' > "$HOME/.local/bin/$1"
        chmod +x "$HOME/.local/bin/$1"
        sleep 0.3
        echo "Installed successfully"
        """

    static let offline = """
        echo "Downloading $1"
        sleep 0.4
        echo "curl: (6) Could not resolve host: downloads.example" >&2
        exit 6
        """
}
