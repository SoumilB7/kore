import AppKit
import KoreCore
import KoreUI
import ObjectiveC

/// Finds storylines, runs the chosen ones one after another in this app, and writes the report.
@MainActor
final class Runner {
    struct Selection {
        var tags: Set<Tag> = []
        var names: Set<String> = []
        var provider: String?
    }

    /// The storyline running now, for the event tap.
    private(set) static var current: StoryContext?
    /// Exceptions AppKit reported since the last step ended: the step fails with them.
    private static var exceptions: [String] = []

    static func exceptionReported(_ exception: NSException) {
        let thrown = exception.callStackSymbols.prefix(12).joined(separator: "\n")
        exceptions.append("Objective-C exception \(exception.name.rawValue): \(exception.reason ?? "")\n\(thrown)")
    }

    private let selection: Selection
    private let flags: RunFlags
    private let out: URL
    private let waits = Waits()
    private let modes: CLIModes

    init(selection: Selection, flags: RunFlags, out: URL) {
        self.selection = selection
        self.flags = flags
        self.out = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        modes = CLIModes(
            mode: flags.cli, run: out, cassettes: flags.cassettes ?? out.appendingPathComponent("cassettes"),
            fakeCLI: flags.fakeCLI, record: flags.record)
        waits.start()
    }

    // MARK: Finding storylines

    /// Every concrete `Storyline` subclass in the process, by name.
    static func discover() -> [Storyline.Type] {
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let got = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), count)
        var found: [Storyline.Type] = []
        for i in 0..<Int(got) {
            let cls: AnyClass = buffer[i]
            // Walk superclasses without messaging the class: most classes in the process aren't ours.
            let root = ObjectIdentifier(Storyline.self)
            var parent: AnyClass? = class_getSuperclass(cls)
            while let p = parent, ObjectIdentifier(p) != root { parent = class_getSuperclass(p) }
            guard parent != nil, let story = cls as? Storyline.Type, !story.isFamily else { continue }
            found.append(story)
        }
        return found.sorted { $0.storyName < $1.storyName }
    }

    func chosen() -> [(Storyline.Type, Variant)] {
        Self.discover()
            .filter { selection.tags.isEmpty || !$0.tags.isDisjoint(with: selection.tags) }
            // A live model only gets storylines written for one (short, fixed prompts).
            .filter { story in if case .live = flags.cli { story.tags.contains(.live) } else { true } }
            .filter { selection.names.isEmpty || selection.names.contains($0.storyName) }
            .flatMap { story in story.variants.map { (story, $0) } }
            .filter { selection.provider == nil || $0.1.provider == nil || $0.1.provider == selection.provider }
    }

    // MARK: Running

    func run() async -> RunReport {
        var report = RunReport()
        do {
            try modes.installRun()
        } catch {
            report.stories = [.init(name: "Set up the CLI", variant: "", steps: [.init(label: "\(flags.cli)", outcome: .fail, error: "\(error)")])]
            try? report.write(to: out)
            return report
        }
        var dropped: [String] = []
        for (story, variant) in chosen() {
            if flags.drop {
                dropped += await dropRun(story, variant)
            } else {
                report.stories.append(await run(story, variant))
            }
        }
        modes.finishRun()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? (StoryHost.touched.sorted().joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("touched.txt"), atomically: true, encoding: .utf8)
        if flags.drop { try? (dropped.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("drop.tsv"), atomically: true, encoding: .utf8) }
        try? report.write(to: out)
        return report
    }

    /// The step's longest stretch without a main run-loop pass, when over 2 s.
    private func stalled() -> Int? {
        let gap = waits.longestGap
        guard gap > .seconds(2) else { return nil }
        return Int(gap.components.seconds * 1000 + gap.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Proving the checks

    /// What a person does, by the step's type; the rest set up, wait or check.
    private static func isInput(_ step: any Step) -> Bool {
        let type = String(describing: Swift.type(of: step))
        let passive = ["Expect", "Wait", "Do", "BoxStep", "Use", "Open", "Start", "Write", "RunGit", "Turn", "Snapshot", "Dump", "Show", "Settle", "DevicesSetUp", "Seed", "Offer", "Import", "DriveChatSettle", "DriveBoxOnWelcome", "Look", "Inside", "Release", "SizeWindow", "Resume", "Set", "Send", "Make", "Queue"]
        // "Do" whole: DoubleClick is an input.
        return type != "Do" && !passive.contains { $0 != "Do" && type.hasPrefix($0) }
    }

    /// One line per input of the storyline: run with it skipped, what failed ("SURVIVED" when
    /// nothing did, so no check of it can fail).
    private func dropRun(_ type: Storyline.Type, _ variant: Variant) async -> [String] {
        let story = type.init()
        story.variant = variant
        let inputs = story.steps().enumerated().filter { Self.isInput($0.element) }.map { ($0.offset, $0.element.label) }
        var lines: [String] = []
        for (index, label) in inputs {
            let result = await run(type, variant, dropping: index)
            let failed = result.steps.first { $0.outcome == .fail }
            lines.append([type.storyName, variant.name, "\(index)", label, failed.map { "failed: " + $0.label } ?? "SURVIVED"].joined(separator: "\t"))
        }
        if inputs.isEmpty { lines.append([type.storyName, variant.name, "-", "no input step", "NONE"].joined(separator: "\t")) }
        return lines
    }

    private func run(_ type: Storyline.Type, _ variant: Variant, dropping: Int? = nil) async -> RunReport.StoryResult {
        let name = (variant.name.isEmpty ? type.storyName : "\(type.storyName)-\(variant.name)") + (dropping.map { "-drop\($0)" } ?? "")
        var result = RunReport.StoryResult(name: type.storyName, variant: variant.name)
        let started = ContinuousClock.now
        let story = type.init()
        WindowSight.offscreenShows = !type.seesOcclusion
        story.variant = variant
        if type.tags.contains(.realInput), !flags.realInput {
            result.steps = [.init(label: "Needs --real-input", outcome: .skip)]
            return result
        }
        // The CLI its chats get: the run's (`CLIModes`), or the real ones on the owner's stores.
        let real = type.needs.cli == .real
        let outside = real ? RealCLIs() : nil
        defer { outside?.restore() }

        let folder: URL
        switch type.needs.folder {
        case .empty:
            folder = out.appendingPathComponent("folders/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        case .replay(let fixture):
            guard let replay = flags.replays[fixture] else {
                result.steps = [.init(label: "Find the replay fixture “\(fixture)”", outcome: .fail, error: "no --replay named \(fixture)")]
                return result
            }
            folder = replay.folder
        }
        if !real {
            do {
                try modes.begin(storyline: type.storyName, provider: variant.provider ?? "claude", folder: folder)
            } catch {
                result.steps = [.init(label: "Set up the \(flags.cli) CLI", outcome: .fail, error: "\(error)")]
                return result
            }
        }
        Self.forgetSaved(folder)
        Workspace.storyLaunch = nil
        // An earlier storyline's usage readings would put the usage mark in this one's composer.
        StoryUsageCue.reset()
        // What the last storyline asked the system for (pages, Finder, a folder picker) is its own.
        StoryZoom.reset()
        // What it leaves in the process's defaults (a key not of its own folder), noted for the run.
        let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let defaultsBefore = UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
        // The windows up before it: any other it opens (a second folder, a box's) goes with it.
        let shownBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        StoryHost.opened = []
        StoryHost.revealed = []
        StoryHost.picks = []
        StoryHost.pickedFolder = nil
        StoryHost.pickedSave = nil
        FilePaste.storyPlans = []
        StoryHost.firstClicks = type.tags.contains(.drive)
        let context = StoryContext(name: name, flags: flags, folder: folder, outputs: out, waits: waits)
        context.windowSize = flags.size ?? type.needs.window
        context.variant = variant
        Self.current = context

        var failed = false
        var skipping = false
        // The owner's clipboard is never a storyline's: a copy goes to the host's own board
        // (StoryHost.board). Any write to the general one in this storyline fails it.
        GeneralPasteboardGuard.install()
        _ = GeneralPasteboardGuard.take()
        let ownerConfig = OwnerConfig.look()
        let seams = SeamHooks.look()
        for (index, step) in story.steps().enumerated() {
            if index == dropping {
                result.steps.append(.init(label: step.label, outcome: .skip))
                continue
            }
            if failed || skipping {
                result.steps.append(.init(label: step.label, outcome: .skip))
                continue
            }
            let stepStart = ContinuousClock.now
            waits.resetGap()
            do {
                // A skipped input's check only has to fail: no long wait for what won't come.
                let limit = dropping == nil ? nil : Duration.seconds(2)
                let timeout = step.timeout ?? .seconds(5)
                context.timeout = limit.map { min($0, timeout) } ?? timeout
                try await step.run(context)
                if !Self.exceptions.isEmpty {
                    defer { Self.exceptions = [] }
                    throw StoryFailure.expectation(Self.exceptions.joined(separator: "\n"))
                }
                result.steps.append(.init(label: step.label, outcome: .pass, ms: ms(since: stepStart), stalledMs: stalled()))
            } catch let skip as StorySkip {
                skipping = true
                print("\(name): \(skip)")
                result.steps.append(.init(label: step.label, outcome: .skip, ms: ms(since: stepStart), error: "\(skip)"))
            } catch {
                failed = true
                result.steps.append(.init(label: step.label, outcome: .fail, ms: ms(since: stepStart), error: "\(error)", stalledMs: stalled()))
                if dropping == nil { result.files += evidence(context, step: result.steps.count) }
            }
        }
        let log = out.appendingPathComponent("\(name).events.log")
        if (try? (context.eventLog + "\n").write(to: log, atomically: true, encoding: .utf8)) != nil {
            result.files.append(log.lastPathComponent)
        }
        context.finish()
        // A hook left behind would answer the next storyline's questions unseen.
        let leaked = seams.putBack()
        // A question left up takes the next storyline's keys and clicks.
        let leftAsking = KoreAsk.storyCancelLeftOpen()
        Self.current = nil
        if let window = context.window {
            window.close()
            // The next storyline may open the same folder: its window has to be gone, or opening
            // the folder would bring this one back.
            _ = try? await waits.until("the window to close", timeout: .seconds(5)) { !window.isVisible ? true : nil }
        }
        // Another window it opened would stay in the next storyline's way (its tabs, its keys).
        let defaultsAfter = UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
        let own = folder.standardizedFileURL.path
        let left = Set(defaultsBefore.keys).union(defaultsAfter.keys).filter { key in
            !key.contains(own) && !key.hasPrefix("NSWindow Frame")
                && (defaultsBefore[key] as? NSObject) != (defaultsAfter[key] as? NSObject)
        }.sorted()
        // Chats it archived stay its own: the next storyline's History lists them again.
        UserDefaults.standard.set(defaultsBefore["archivedClaudeSessions"], forKey: "archivedClaudeSessions")
        if !left.isEmpty {
            let line = "\(name)\t\(left.joined(separator: ","))\n"
            let file = out.appendingPathComponent("defaults-left.tsv")
            if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? line.write(to: file, atomically: true, encoding: .utf8) }
        }
        let opened = NSApp.windows.filter { $0.isVisible && !shownBefore.contains(ObjectIdentifier($0)) }
        for extra in opened { extra.close() }
        if !opened.isEmpty { _ = try? await waits.until("its other windows to close", timeout: .seconds(5)) { opened.allSatisfy { !$0.isVisible } ? true : nil } }
        if !real {
            result.files += modes.end().map { "removed \($0.path)" }
        }
        result.ms = ms(since: started)
        if let changed = OwnerConfig.changed(since: ownerConfig) {
            result.steps.append(.init(label: "The owner's Claude and Codex settings left alone", outcome: .fail,
                                      error: "this storyline changed \(changed); a storyline writes only its run's CLAUDE_CONFIG_DIR and CODEX_HOME"))
        }
        if let leftAsking {
            result.steps.append(.init(label: "No question left up", outcome: .fail, error: "this storyline left Kore's “\(leftAsking)” question up"))
        }
        if !leaked.isEmpty {
            result.steps.append(.init(label: "Its storyline seams taken out", outcome: .fail,
                                      error: "this storyline left \(leaked.joined(separator: ", ")) set; take it out with story.atFinish"))
        }
        let wrote = GeneralPasteboardGuard.take()
        if !wrote.isEmpty {
            result.steps.append(.init(label: "The owner's clipboard left alone", outcome: .fail,
                                      error: "this storyline wrote NSPasteboard.general (kept on the host's board instead): \(wrote.prefix(3).joined(separator: "; "))"))
        }
        return result
    }

    /// The folder's remembered tabs, explorer and the like ("openTabs.<path>", …), so each
    /// storyline opens it fresh. Only the `kore-storylines` defaults domain is touched.
    private static func forgetSaved(_ folder: URL) {
        let suffix = "." + folder.standardizedFileURL.path
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The window and the rows when a step fails.
    private func evidence(_ context: StoryContext, step: Int) -> [String] {
        var files: [String] = []
        let base = "\(context.name)-step\(step)"
        if let window = context.window, let png = snapshot(window) {
            let url = out.appendingPathComponent("\(base).png")
            if (try? png.write(to: url)) != nil { files.append(url.lastPathComponent) }
        }
        if let chat = context.app.chat {
            let url = out.appendingPathComponent("\(base).rows.txt")
            if (try? chat.dumpLines().joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil {
                files.append(url.lastPathComponent)
            }
        }
        return files
    }

    private func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// For one storyline on the real CLIs and the owner's stores (`Needs.CLI.real`): the scripted
/// backend, CLI stand-ins and scratch Claude store are set aside, and put back after.
@MainActor
private final class RealCLIs {
    private let backend = StorylineSeams.backend
    private let accounts = StorylineSeams.accounts
    private let standIns = CLIExecutable.standIns.value
    private let claudeStore = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]

    init() {
        StorylineSeams.backend = nil
        StorylineSeams.accounts = nil
        CLIExecutable.standIns.value = [:]
        unsetenv("CLAUDE_CONFIG_DIR")
    }

    func restore() {
        StorylineSeams.backend = backend
        StorylineSeams.accounts = accounts
        CLIExecutable.standIns.value = standIns
        if let claudeStore { setenv("CLAUDE_CONFIG_DIR", claudeStore, 1) }
    }
}

/// `StorylineSeams` as they were before a storyline's steps, put back after it.
@MainActor
struct SeamHooks {
    private let set: [String: Bool]
    private let back: @MainActor () -> Void

    private static func hooks() -> [String: Bool] {
        ["backend": StorylineSeams.backend != nil, "events": StorylineSeams.events != nil,
         "accounts": StorylineSeams.accounts != nil, "loginUsage": StorylineSeams.loginUsage != nil,
         "opened": StorylineSeams.opened != nil, "confirm": StorylineSeams.confirm != nil,
         "chooseFile": StorylineSeams.chooseFile != nil, "sessions": StorylineSeams.sessions != nil,
         "historyFile": StorylineSeams.historyFile != nil, "sshHosts": StorylineSeams.sshHosts != nil]
    }

    static func look() -> SeamHooks {
        let (backend, events, accounts) = (StorylineSeams.backend, StorylineSeams.events, StorylineSeams.accounts)
        let (opened, chooseFile, sessions) = (StorylineSeams.opened, StorylineSeams.chooseFile, StorylineSeams.sessions)
        return SeamHooks(set: hooks()) {
            // The run's own hooks as they were; a storyline's always out.
            StorylineSeams.backend = backend
            StorylineSeams.events = events
            StorylineSeams.accounts = accounts
            StorylineSeams.opened = opened
            StorylineSeams.chooseFile = chooseFile
            StorylineSeams.sessions = sessions
            StorylineSeams.loginUsage = nil
            StorylineSeams.confirm = nil
            StorylineSeams.historyFile = nil
            StorylineSeams.sshHosts = nil
        }
    }

    /// Puts them back; the ones the storyline left changed.
    func putBack() -> [String] {
        let now = Self.hooks()
        back()
        return set.keys.sorted().filter { now[$0] != set[$0] }
    }

    private init(set: [String: Bool], back: @escaping @MainActor () -> Void) {
        self.set = set
        self.back = back
    }
}

/// The owner's CLI settings files, looked at (never opened) before and after each storyline: a
/// storyline that changes one fails. Only these files, not their folders: live CLI sessions write
/// ~/.claude and ~/.codex themselves all the time.
enum OwnerConfig {
    typealias Look = [String: Date?]
    /// The owner's home, as the account has it (HOME may be a run's own).
    static let home = FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser
    static let files = [".claude/settings.json", ".claude/settings.local.json", ".codex/config.toml"]

    static func look() -> Look {
        var seen: Look = [:]
        for name in files {
            let path = home.appendingPathComponent(name).path
            // A file's modification time, or nil while there's none: stat only.
            seen[name] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return seen
    }

    /// The files that changed (written, made or removed) since `before`; nil when none did.
    static func changed(since before: Look) -> String? {
        let now = look()
        let changed = files.filter { (before[$0] ?? nil) != (now[$0] ?? nil) }.map { "~/" + $0 }
        return changed.isEmpty ? nil : changed.joined(separator: ", ")
    }
}
