import Foundation
import KoreCore
import KoreLink
import KoreUI

/// The agent channel end to end (`z-docs/agent-protocol.md`), through the built `kore` binary
/// run as a terminal would run it. A grant alone opens nothing while the switch is off; the
/// switch on, the socket appears. `kore` from outside Kore's chats is refused until the test seam
/// lets external callers watch; then `kore ls` lists the chat, `kore log` reads its turn, a
/// follow sees the next turn's rows and its wait on a card, and `kore pending` lists that card.
/// Stop all closes the socket, and `kore` is refused again.
final class AgentWatchReads: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    static let first = "Say hello"
    static let reply = "Hello, read by kore."
    static let second = "List the folder"
    static let listed = "Listed it."
    static let card = Approval(id: "ls1", title: "Run ls -la", detail: "List the folder", body: "ls -la", canAlwaysAllow: false, questions: [])
    override class var script: CLIScript {
        CLIScript(turns: [
            CLIScript.reply(reply),
            [.startTurn, .approval(card, allow: Beat.answer(listed), deny: []), .finishTurn(.completed)],
        ])
    }

    override func steps() -> [any Step] {
        let follow = KoreRun()
        func short(_ story: StoryContext) throws -> String { String(try story.activeChat().id.uuidString.prefix(8)).lowercased() }
        return super.steps() + [
            Do("agent control in a folder of this run's") { _ in
                AgentChannel.directory = URL(fileURLWithPath: "/tmp/kas-\(UUID().uuidString.prefix(8))", isDirectory: true)
                AgentGrants.setEnabled(false)
            },
            Do("grant the chat Read, with the switch off") { story in AgentGrants.set(.watch, chat: try story.activeChat().id.uuidString) },
            Expect("no socket while the switch is off") { _ in AgentChannel.current == nil && !Self.socketExists },
            Do("turn the switch on") { _ in AgentGrants.setEnabled(true) },
            Expect("the socket, 0600") { _ in AgentChannel.current != nil && Self.socketMode == 0o600 },
            Send(Self.first),
            TurnFinished(1),
            RunKore(["ls"], "refused: external callers aren't served") { status, out in status == 5 && out.contains("Only Kore's chats") },
            Do("let external callers watch (the test seam)") { _ in AgentGrants.setExternal(.watch) },
            RunKore(["whoami"], "external, watching") { status, out in status == 0 && out.contains("external · Read") },
            RunKore(["ls"], "the chat, idle", expect: { story in [try short(story), "idle", try story.activeChat().provider.id] }),
            RunKore(["log", "{short}"], "the first turn", expect: { _ in ["› " + Self.first, Self.reply] }),
            Do("follow the chat") { story in try follow.start(["log", try short(story), "-f", "--json", "-n", "1"]) },
            Expect("following") { _ in AgentChannel.current?.connections == 1 && AgentTaps.on },
            Send(Self.second),
            Expect("the follow saw the message and the wait", found: { _ in follow.output }) { _ in
                follow.output.contains(Self.second) && follow.output.contains("\"needs-you\"")
            },
            RunKore(["pending"], "the card", expect: { story in [try short(story), Self.card.title] }),
            RunKore(["pending", "--json"], "the card's id") { status, out in status == 0 && out.contains("\"id\":\"ls1\"") },
            Answer(.allow),
            TurnFinished(2),
            Expect("the follow saw the answer", found: { _ in follow.output }) { _ in follow.output.contains(Self.listed) },
            Do("stop following") { _ in follow.stop() },
            Expect("no follower, taps off") { _ in AgentChannel.current?.connections == 0 && !AgentTaps.on },
            Do("stop all") { _ in AgentGrants.stopAll() },
            Expect("no channel, no socket") { _ in AgentChannel.current == nil && !Self.socketExists },
            RunKore(["ls"], "refused: agent control off") { status, out in status == 5 && out.contains("agent control is off") },
            Do("the switch back off") { _ in AgentGrants.setEnabled(false) },
        ]
    }

    static var socketPath: String { AgentChannel.directory.appendingPathComponent(AgentChannel.socketName).path }
    static var socketExists: Bool { FileManager.default.fileExists(atPath: socketPath) }
    static var socketMode: Int? { (try? FileManager.default.attributesOfItem(atPath: socketPath))?[.posixPermissions] as? Int }
}

/// The built `kore` (beside this app's binary), run as a terminal would: outside Kore's chats,
/// with no pass, at this run's socket; or, with `under`, inside a chat's process tree: a stand-in
/// for the chat's CLI that Kore records as started with that chat's pass (the seam a real launch
/// goes through), with `kore` its child, as a tool's shell would run it. Its output is read off
/// the main thread.
final class KoreRun: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended: Int32?
    private var eof = false
    private var began: ContinuousClock.Instant?
    private var took: Duration?
    private var process: Process?
    private var input: FileHandle?

    static var binary: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("kore-command") }

    var output: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    /// Its exit status, once it has exited and everything it wrote is read.
    var status: Int32? { lock.withLock { eof ? ended : nil } }
    /// From its start (under a stand-in: from the go) to its exit.
    var elapsed: Duration? { lock.withLock { took } }
    var pid: pid_t? { process?.processIdentifier }

    /// `pass`: the KORE_AGENT_PASS it carries. `under`: the pass of the chat whose CLI it runs
    /// under (nil: outside every chat). `input`: written to its stdin, which closes after unless
    /// `keepInput`. `environment`: more variables.
    @MainActor
    func start(
        _ arguments: [String], pass: String? = nil, under cli: String? = nil, input: Data? = nil, keepInput: Bool = false,
        executable: URL? = nil, environment extra: [String: String] = [:]
    ) throws {
        let process = Process()
        let binary = executable ?? Self.binary
        var environment = ProcessInfo.processInfo.environment
        environment["KORE_AGENT_PASS"] = pass
        environment["KORE_AGENT_SOCKET"] = AgentWatchReads.socketPath
        environment.merge(extra) { $1 }
        if cli != nil {
            // Waits for its go (once Kore has recorded it), then runs `kore` as its child.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-fc", "zmodload zsh/datetime; read -r _; s=$EPOCHREALTIME; \"$@\"; c=$?; "
                    + "[[ -n ${KORE_RUN_MS-} ]] && print -r -- $(( (EPOCHREALTIME - s) * 1000 )) >> $KORE_RUN_MS; exit $c",
                "cli", binary.path,
            ] + arguments
        } else {
            process.executableURL = binary
            process.arguments = arguments
        }
        process.environment = environment
        let pipe = Pipe()
        let stdin = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = stdin
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.lock.withLock { self?.eof = true }
                return
            }
            self?.lock.withLock { self?.data.append(chunk) }
        }
        process.terminationHandler = { [weak self] p in
            if cli != nil { AgentPasses.shared.ended(p.processIdentifier) }
            self?.lock.withLock {
                self?.ended = p.terminationStatus
                self?.took = self?.began.map { ContinuousClock.now - $0 }
            }
        }
        lock.withLock {
            data = Data()
            ended = nil
            eof = false
            took = nil
        }
        self.process = process
        try process.run()
        if let cli { AgentPasses.shared.register(cli, pid: process.processIdentifier) }
        lock.withLock { began = ContinuousClock.now }
        var first = cli != nil ? Data("go\n".utf8) : Data()
        if let input { first.append(input) }
        if !first.isEmpty { try? stdin.fileHandleForWriting.write(contentsOf: first) }
        if keepInput { self.input = stdin.fileHandleForWriting } else { try? stdin.fileHandleForWriting.close() }
    }

    /// More on its stdin (`keepInput`).
    func write(_ more: Data) { try? input?.write(contentsOf: more) }

    /// Closes its stdin.
    func closeInput() {
        try? input?.close()
        input = nil
    }

    func stop() { process?.terminate() }
}

/// Runs `kore <arguments>` to its end and checks its exit status and output. `{short}` in an
/// argument is the active chat's short id.
struct RunKore: Step {
    let arguments: [String]
    let what: String
    let check: @MainActor (StoryContext, Int32, String) throws -> Bool
    var label: String { "kore \(arguments.joined(separator: " ")): \(what)" }
    var timeout: Duration? { .seconds(15) }

    init(_ arguments: [String], _ what: String, _ check: @escaping @MainActor (Int32, String) -> Bool) {
        self.arguments = arguments
        self.what = what
        self.check = { _, status, out in check(status, out) }
    }

    /// Exits 0 and prints every one of `expect`'s strings.
    init(_ arguments: [String], _ what: String, expect: @escaping @MainActor (StoryContext) throws -> [String]) {
        self.arguments = arguments
        self.what = what
        self.check = { story, status, out in try status == 0 && expect(story).allSatisfy { out.contains($0) } }
    }

    @MainActor func run(_ story: StoryContext) async throws {
        let short = String(try story.activeChat().id.uuidString.prefix(8)).lowercased()
        let run = KoreRun()
        try run.start(arguments.map { $0 == "{short}" ? short : $0 })
        try await story.until("kore to exit", timeout: timeout) { run.status != nil }
        let status = run.status ?? -1
        guard try check(story, status, run.output) else {
            throw StoryFailure.expectation("\(what) (exit \(status): \(run.output.prefix(400)))")
        }
    }
}
