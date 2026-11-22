import AgentTools
import Foundation
@testable import src
import Testing

@testable import KoreCore
@testable import KoreUI

/// Claude's Full access (owner, 2026-11-21): the CLI's bypassPermissions, named, drawn and ranked
/// as Codex's Full access. claude 2.1.318 takes `set_permission_mode` bypassPermissions only from a
/// process launched in it (or with `--allow-dangerously-skip-permissions`), so a chat not launched
/// in it starts again in it, between turns; every other launch keeps its flags. Only a person
/// raises a chat into it; Arsenal moves it only as high as the chat asking.
extension HostOverrideTests {
@MainActor
@Suite("Claude's Full access", .serialized)
struct ClaudeFullAccessTests {
    // MARK: The mode

    @Test func itIsListedAsCodexsFullAccess() throws {
        let claude = try #require(ClaudeModes.all.first { $0.id == ClaudeModes.fullAccess })
        let codex = try #require(CodexModes.all.first { $0.id == CodexModes.fullAccess })
        #expect(ClaudeModes.fullAccess == "bypassPermissions")
        #expect(claude.label == "Full access" && claude.label == codex.label)
        #expect(claude.icon == codex.icon && claude.iconSize == codex.iconSize && claude.rung == codex.rung && claude.rung == .danger)
        #expect(claude.listed && claude.level == 4 && claude.level == codex.level)
        // Above Auto, in the menu whichever the model; Don't ask stays out of it.
        let ids = ProviderDescriptor.claude.availableModes(nil).map(\.id)
        #expect(ids == ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])
        let noAuto = ModelOption(id: "small", name: "Small", resolved: "small", efforts: [], supportsAutoMode: false)
        #expect(ProviderDescriptor.claude.availableModes(noAuto).map(\.id) == ["default", "acceptEdits", "plan", "bypassPermissions"])
    }

    @Test func shiftTabNeverCyclesIntoIt() {
        let available = ProviderDescriptor.claude.availableModes(nil)
        var mode = "default"
        var seen: [String] = []
        for _ in 0..<6 {
            guard case .mode(let next) = ProviderDescriptor.claude.nextMode(mode, false, available) else { Issue.record("not a mode"); return }
            seen.append(next)
            mode = next
        }
        #expect(!seen.contains(ClaudeModes.fullAccess))
        // From Full access, Shift+Tab lowers to Manual.
        guard case .mode(let down) = ProviderDescriptor.claude.nextMode(ClaudeModes.fullAccess, false, available) else { Issue.record("not a mode"); return }
        #expect(down == "default")
    }

    @Test func aBoxChatShowsItDimAboveAuto() {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-full-access"), modeMemory: ModeMemory(defaults: nil))
        chat.controls.levelCap = 3
        #expect(!chat.controls.availableModes.contains { $0.id == ClaudeModes.fullAccess })
        #expect(chat.controls.cappedModes.map(\.label) == ["Full access"])
    }

    // MARK: Launch flags

    @Test func onlyAFullAccessLaunchCarriesABypassFlag() {
        let folder = URL(fileURLWithPath: "/tmp/kore-full-access")
        for mode in ClaudeSession.PermissionMode.allCases where mode != .bypassPermissions {
            let args = ClaudeSession.Options(cwd: folder, permissionMode: mode).arguments
            #expect(!args.contains { $0.contains("dangerously") }, "\(mode)")
            #expect(Self.value(of: "--permission-mode", in: args) == mode.rawValue)
        }
        let args = ClaudeSession.Options(cwd: folder, permissionMode: .bypassPermissions).arguments
        #expect(Self.value(of: "--permission-mode", in: args) == "bypassPermissions")
        #expect(args.contains("--allow-dangerously-skip-permissions") && !args.contains("--dangerously-skip-permissions"))
    }

    // MARK: Hook

    @Test func koresAskHookStaysAutoOnly() {
        let saved = ClaudeBackend.askHook
        defer { ClaudeBackend.askHook = saved }
        ClaudeBackend.askHook = "'/k/kore' hook pretool"
        let pass = KoreAskList.Pass(command: "make", cwd: "/tmp/kore-full-access", until: .distantFuture)
        #expect(ClaudeBackend.askHook(for: ClaudeModes.fullAccess, pass: pass) == nil)
        #expect(ClaudeBackend.askHook(for: "auto", pass: pass) != nil)
        let args = { (mode: ClaudeSession.PermissionMode) in
            var options = ClaudeSession.Options(cwd: URL(fileURLWithPath: "/tmp/kore-full-access"), permissionMode: mode)
            options.askHook = ClaudeBackend.askHook(for: mode.rawValue, pass: pass)
            return options.arguments.joined(separator: " ")
        }
        #expect(!args(.bypassPermissions).contains("PreToolUse") && args(.auto).contains("PreToolUse"))
    }

    // MARK: Arsenal

    private func chat(_ mode: String) -> Chat {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-full-access"), modeMemory: ModeMemory(defaults: nil))
        chat.controls.mode = mode
        return chat
    }

    @Test func arsenalNeverRaisesAChatIntoIt() {
        // Its own chat, from Auto: never up.
        let own = chat("auto")
        #expect(!own.arsenalMayMove(to: ClaudeModes.fullAccess))
        guard case .failure(let refusal) = own.arsenalMode(ClaudeModes.fullAccess) else { Issue.record("raised its own chat"); return }
        #expect(refusal.message.hasPrefix("Only you can raise a chat's mode. Full access is above Auto."))
        #expect(own.arsenalOptions.modes.first { $0.id == ClaudeModes.fullAccess }.map { !$0.allowed && $0.label == "Full access" } == true)
        // Another's, by a caller in Auto: no freer than the caller.
        let caller = chat("auto")
        let other = chat("default")
        #expect(!other.arsenalMayMove(to: ClaudeModes.fullAccess, under: caller))
        guard case .failure(let raise) = other.arsenalMode(ClaudeModes.fullAccess, under: caller) else { Issue.record("raised past the caller"); return }
        #expect(raise.message == "Full access would let this chat do more on its own than Auto lets the chat asking: only you can.")
        #expect(other.controls.mode == "default")
        // A woken or forked chat's mode: capped at the caller's, whichever CLI.
        for (mode, cap) in [(ClaudeModes.fullAccess, "auto"), (ClaudeModes.fullAccess, "acceptEdits"), (CodexModes.fullAccess, "auto")] {
            #expect(!Chat.noFreer(mode, unreviewed: false, than: cap, unreviewed: false), "\(mode) under \(cap)")
        }
        // A caller the person put in Full access reaches its level, as with Codex's.
        #expect(Chat.noFreer(ClaudeModes.fullAccess, unreviewed: false, than: CodexModes.fullAccess, unreviewed: false))
        #expect(other.arsenalMayMove(to: ClaudeModes.fullAccess, under: chat(ClaudeModes.fullAccess)))
    }

    @Test func arsenalMayLowerOutOfIt() {
        let full = chat(ClaudeModes.fullAccess)
        for mode in ["default", "acceptEdits", "plan", "auto"] { #expect(full.arsenalMayMove(to: mode), "\(mode)") }
        guard case .success(let said) = full.arsenalMode("auto") else { Issue.record("refused a lowering"); return }
        #expect(said == "Mode Auto.")
    }

    // MARK: Switching, against a stand-in CLI

    /// A claude stand-in: writes each launch's arguments to `ARGS`, answers every control request,
    /// and refuses bypassPermissions as claude 2.1.318 does when not launched able to bypass. With
    /// `ROOT`, a bypass launch ends at once as the CLI does under root.
    private static let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        argv = sys.argv[1:]
        with open(os.environ["ARGS"], "a") as f: f.write(" ".join(argv) + "\n")
        mode = argv[argv.index("--permission-mode") + 1]
        able = mode == "bypassPermissions" or "--allow-dangerously-skip-permissions" in argv
        if os.environ.get("ROOT") and able:
            sys.stderr.write("--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons\n")
            sys.exit(1)
        def say(o): print(json.dumps(o), flush=True)
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") != "control_request": continue
            rid, req = m["request_id"], m["request"]
            if req.get("subtype") == "set_permission_mode":
                if req["mode"] == "bypassPermissions" and not able:
                    say({"type": "control_response", "response": {"subtype": "error", "request_id": rid,
                        "error": "Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions"}})
                    continue
                say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
                say({"type": "system", "subtype": "status", "status": None, "permissionMode": req["mode"], "session_id": "s"})
                continue
            say({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        """#

    private struct Rig {
        let folder: URL
        let args: URL
        var launches: [String] { ((try? String(contentsOf: args, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    private func rig(root: Bool = false) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-full-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = folder.appendingPathComponent("claude")
        try Self.script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let args = folder.appendingPathComponent("args")
        var environment = ["ARGS": args.path, "HOME": folder.path]
        if root { environment["ROOT"] = "1" }
        CLIExecutable.standIns.value = ["claude": .init(executable: fake, environment: environment)]
        return Rig(folder: folder, args: args)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    private static func launchMode(_ line: String) -> String? { value(of: "--permission-mode", in: line.split(separator: " ").map(String.init)) }

    /// The mode changes the backend said, in order.
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ModeChange] = []
        var all: [ModeChange] { lock.withLock { list } }
        func add(_ change: ModeChange) { lock.withLock { list.append(change) } }
    }

    private func watch(_ backend: ClaudeBackend) -> Changes {
        let changes = Changes()
        Task {
            for await event in backend.events {
                if case .modeChanged(let change) = event { changes.add(change) }
            }
        }
        return changes
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pickingItStartsTheCLIAgainInItAndOnlyThen() async throws {
        let previous = CLIExecutable.standIns.value
        defer { CLIExecutable.standIns.value = previous }
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let backend = ClaudeBackend(BackendOptions(folder: rig.folder, mode: "default"))
        let changes = watch(backend)
        try await backend.start()
        #expect(rig.launches.count == 1 && Self.launchMode(rig.launches[0]) == "default")
        #expect(!rig.launches[0].contains("dangerously"))
        // Other modes switch in place.
        try await backend.setMode("acceptEdits")
        try await until("acceptEdits") { changes.all.last?.mode == "acceptEdits" }
        #expect(rig.launches.count == 1)
        // Full access: the CLI starts again in it, and the transcript says so as a pick.
        try await backend.setMode(ClaudeModes.fullAccess)
        #expect(rig.launches.count == 2)
        #expect(Self.launchMode(rig.launches[1]) == "bypassPermissions" && rig.launches[1].contains("--allow-dangerously-skip-permissions"))
        try await until("Full access said") { changes.all.last?.mode == ClaudeModes.fullAccess }
        #expect(changes.all.last == ModeChange(mode: ClaudeModes.fullAccess, previous: "acceptEdits", source: .user, at: changes.all.last?.at ?? .now))
        // Down and up again: the process launched in it takes both in place.
        try await backend.setMode("default")
        try await until("lowered") { changes.all.last?.mode == "default" }
        try await backend.setMode(ClaudeModes.fullAccess)
        try await until("raised in place") { changes.all.last?.mode == ClaudeModes.fullAccess }
        #expect(rig.launches.count == 2)
        await backend.close()
    }

    @Test func aTurnUnderWayKeepsTheCLIAndTheMode() async throws {
        let previous = CLIExecutable.standIns.value
        defer { CLIExecutable.standIns.value = previous }
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let translator = ClaudeTranslator(folder: rig.folder, sessionId: nil)
        translator.translate(.textDelta("Working", parentToolUseId: nil))
        #expect(translator.turn != nil)
        let backend = ClaudeBackend(BackendOptions(folder: rig.folder, mode: "default"), translator: translator)
        try await backend.start()
        await #expect(throws: ClaudeBackend.FullAccessRefused.self) { try await backend.setMode(ClaudeModes.fullAccess) }
        #expect(rig.launches.count == 1)
        // The mode it was in stays the one a later launch takes.
        await backend.relaunch(reason: "test")
        try await backend.start()
        #expect(rig.launches.count == 2 && Self.launchMode(rig.launches[1]) == "default")
        await backend.close()
    }

    @Test func aLaunchTheCLIRefusesGoesBackToTheModeItWasIn() async throws {
        let previous = CLIExecutable.standIns.value
        defer { CLIExecutable.standIns.value = previous }
        let rig = try rig(root: true)
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let backend = ClaudeBackend(BackendOptions(folder: rig.folder, mode: "auto"))
        try await backend.start()
        await #expect(throws: (any Error).self) { try await backend.setMode(ClaudeModes.fullAccess) }
        // Started in Full access, refused (as under root), and back in Auto.
        #expect(rig.launches.map { Self.launchMode($0) } == ["auto", "bypassPermissions", "auto"])
        try await backend.setMode("acceptEdits")
        #expect(rig.launches.count == 3)
        await backend.close()
    }
}
}
