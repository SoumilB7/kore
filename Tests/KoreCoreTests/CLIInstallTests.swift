import Foundation
import Testing

@testable import KoreCore

/// Finding the claude and codex CLIs in the fixed list of places, and installing them: the ways a
/// Mac has, the installer's stages and its failure's one reason. Nothing here touches the real
/// installs: a temp HOME stands in for the Mac, and a script for the installer.
@Suite("CLI lookup and install", .serialized)
struct CLIInstallTests {
    /// A temp HOME with `files` (relative paths) as executables answering `--version`.
    private func mac(_ files: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for file in files {
            let url = home.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho 1.0.0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return home
    }

    private func places(_ home: URL, path: [String] = []) -> CLILocator.Places {
        CLILocator.Places(home: home, path: path.map { home.path + "/" + $0 }, system: [], applications: [home.appendingPathComponent("Applications")])
    }

    private func found(_ name: String, in home: URL, path: [String] = []) -> [String] {
        CLILocator.candidates(name, in: places(home, path: path)).map {
            "\($0.source):" + String($0.url.path.dropFirst(home.path.count + 1))
        }
    }

    @Test("every known place for Claude Code, in order")
    func claudePlaces() throws {
        let home = try mac([
            "tools/bin/claude",
            ".local/share/claude/versions/2.0.9",
            ".local/share/claude/versions/2.0.10",
            ".claude/local/claude",
            ".nvm/versions/node/v18.20.1/bin/claude",
            ".nvm/versions/node/v22.4.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
            ".bun/bin/claude",
            "Applications/Claude.app/Contents/Resources/claude",
            ".vscode/extensions/anthropic.claude-code-2.0.3-darwin-arm64/resources/native-binary/claude",
            ".vscode/extensions/anthropic.claude-code-2.0.12-darwin-arm64/resources/native-binary/claude",
            ".cursor/extensions/anthropic.claude-code-1.9.0/resources/native-binary/claude",
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(found("claude", in: home, path: ["tools/bin"]) == [
            "path:tools/bin/claude",
            "native:.local/share/claude/versions/2.0.10",
            "native:.local/share/claude/versions/2.0.9",
            "native-local:.claude/local/claude",
            "nvm:.nvm/versions/node/v22.4.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
            "nvm:.nvm/versions/node/v18.20.1/bin/claude",
            "bun:.bun/bin/claude",
            "app:Applications/Claude.app/Contents/Resources/claude",
            "vscode:.vscode/extensions/anthropic.claude-code-2.0.12-darwin-arm64/resources/native-binary/claude",
            "vscode:.vscode/extensions/anthropic.claude-code-2.0.3-darwin-arm64/resources/native-binary/claude",
            "cursor:.cursor/extensions/anthropic.claude-code-1.9.0/resources/native-binary/claude",
        ])
    }

    @Test("every known place for Codex, in order")
    func codexPlaces() throws {
        let home = try mac([
            ".local/bin/codex",
            ".codex/packages/standalone/current/bin/codex",
            ".volta/bin/codex",
            "Applications/Codex.app/Contents/Resources/codex",
            ".windsurf/extensions/openai.chatgpt-0.4.1/bin/macos-aarch64/codex",
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(found("codex", in: home) == [
            "local-bin:.local/bin/codex",
            "standalone:.codex/packages/standalone/current/bin/codex",
            "volta:.volta/bin/codex",
            "app:Applications/Codex.app/Contents/Resources/codex",
            "windsurf:.windsurf/extensions/openai.chatgpt-0.4.1/bin/macos-aarch64/codex",
        ])
    }

    @Test("an app's own binary isn't the CLI, a link counts once, and only the two CLIs are known")
    func notTheCLI() throws {
        let home = try mac(["Applications/Claude.app/Contents/MacOS/Claude", ".local/share/claude/versions/2.1.0"])
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("claude"), withDestinationURL: home.appendingPathComponent(".local/share/claude/versions/2.1.0"))
        // The desktop app's `Claude` isn't `claude` on a volume that ignores case.
        #expect(found("claude", in: home) == ["local-bin:.local/bin/claude"])
        #expect(found("git", in: home).isEmpty)
    }

    @Test("Locate…'s pick comes first")
    func chosenFirst() throws {
        let home = try mac(["picked/claude", ".local/bin/claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        var custom = places(home)
        custom.chosen = home.appendingPathComponent("picked/claude")
        #expect(CLILocator.candidates("claude", in: custom).map(\.source) == ["chosen", "local-bin"])
    }

    @Test("the lookup takes the first candidate whose --version answers")
    func versionCheck() async throws {
        let home = try mac([".local/share/claude/versions/2.0.1"])
        defer { try? FileManager.default.removeItem(at: home) }
        // A broken binary first: it exits 1 to --version.
        let broken = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        CLIExecutable.look(in: places(home))
        defer { CLIExecutable.look(in: nil) }
        #expect(await CLIExecutable.located("claude")?.lastPathComponent == "2.0.1")
        #expect(await CLIExecutable.located("codex") == nil)
    }

    @Test("--locate-cli: only when asked, and only for the two CLIs")
    func headless() {
        #expect(CLIExecutable.headless(["Kore"]) == nil)
        #expect(CLIExecutable.headless(["Kore", "--locate-cli", "git"]) == 2)
    }

    @Test("the ways to install: the official installer always, Homebrew and npm when found")
    func methods() {
        #expect(CLIInstaller.methods { _ in false } == [.official])
        #expect(CLIInstaller.methods { $0 == "npm" } == [.official, .npm])
        #expect(CLIInstaller.methods { _ in true } == [.official, .homebrew, .npm])
        #expect(CLIInstaller.command(.official, for: "claude") == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(CLIInstaller.command(.official, for: "codex") == "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        #expect(CLIInstaller.command(.homebrew, for: "codex") == "brew install --cask codex")
        #expect(CLIInstaller.command(.npm, for: "claude") == "npm i -g @anthropic-ai/claude-code")
        #expect(CLIInstaller.command(.npm, for: "git") == nil)
    }

    @Test("a failure's one reason")
    func reasons() {
        #expect(CLIInstaller.reason(output: "curl: (6) Could not resolve host: claude.ai", status: 6) == .offline)
        #expect(CLIInstaller.reason(output: "npm ERR! request to https://registry.npmjs.org failed, reason: getaddrinfo ENOTFOUND", status: 1) == .offline)
        #expect(CLIInstaller.reason(output: "mkdir: /usr/local/lib: Permission denied", status: 1) == .permission)
        #expect(CLIInstaller.reason(output: "npm ERR! code EACCES", status: 243) == .permission)
        #expect(CLIInstaller.reason(output: "", status: 126) == .permission)
        #expect(CLIInstaller.reason(output: "Error: checksum mismatch", status: 1) == .other)
        #expect(CLIInstaller.Reason.offline.text == "No internet connection.")
    }

    @Test("the stage line, with the size when the installer gives it")
    func stages() {
        var progress = CLIInstaller.Progress()
        #expect(progress.text == "Starting")
        progress = CLIInstaller.progress(after: "Downloading Claude Code…", progress)
        #expect(progress.text == "Downloading")
        progress = CLIInstaller.progress(after: "  18.0 MB / 29.0 MB", progress)
        #expect(progress.text == "Downloading · 18 of 29 MB")
        let half = progress.fraction
        progress = CLIInstaller.progress(after: "Verifying checksum", progress)
        #expect(progress.stage == .verifying && progress.fraction > half)
        progress = CLIInstaller.progress(after: "Installing to ~/.local/bin", progress)
        #expect(progress.text == "Installing")
        // Never back: a later "download" word doesn't undo it.
        progress = CLIInstaller.progress(after: "downloaded", progress)
        #expect(progress.stage == .installing)
        #expect(CLIInstaller.progress(after: "######  62.5%", CLIInstaller.Progress()).percent == 0.625)
    }

    @Test("an install runs the stand-in script, reporting stages; offline fails with that reason")
    func runs() async throws {
        let home = try mac([])
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("installer.sh")
        try """
            echo "Downloading $1 · 3 of 6 MB"
            mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\\necho 1\\n' > "$HOME/.local/bin/$1" && chmod +x "$HOME/.local/bin/$1"
            echo "Installed"
            """.write(to: script, atomically: true, encoding: .utf8)
        let seen = Locked<[String]>([])
        CLIInstaller.standIn.value = .init(script: script, environment: ["HOME": home.path])
        defer { CLIInstaller.standIn.value = nil }
        try await CLIInstaller.install("codex", method: .official) { progress in seen.withLock { $0.append(progress.text) } }
        #expect(seen.value.contains("Downloading · 3 of 6 MB"))
        #expect(FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".local/bin/codex").path))

        try "echo 'curl: (7) Failed to connect to chatgpt.com' >&2; exit 7\n".write(to: script, atomically: true, encoding: .utf8)
        await #expect(throws: CLIInstaller.Reason.offline) {
            try await CLIInstaller.install("codex", method: .official) { _ in }
        }
    }

    @Test("Cancel ends the installer and everything it started")
    func cancels() async throws {
        let home = try mac([])
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("installer.sh")
        try "echo Downloading; sleep 30 | cat; echo done\n".write(to: script, atomically: true, encoding: .utf8)
        CLIInstaller.standIn.value = .init(script: script, environment: ["HOME": home.path])
        defer { CLIInstaller.standIn.value = nil }
        let running = Locked(false)
        let run = Task { try await CLIInstaller.install("claude", method: .official) { _ in running.set(true) } }
        // Cancelled once it runs (its first line in), not before it starts.
        while !running.value { try await Task.sleep(for: .milliseconds(20)) }
        let started = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
