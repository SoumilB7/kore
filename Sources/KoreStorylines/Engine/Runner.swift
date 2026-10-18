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
        for (story, variant) in chosen() {
            report.stories.append(await run(story, variant))
        }
        modes.finishRun()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? report.write(to: out)
        return report
    }

    private func run(_ type: Storyline.Type, _ variant: Variant) async -> RunReport.StoryResult {
        let name = variant.name.isEmpty ? type.storyName : "\(type.storyName)-\(variant.name)"
        var result = RunReport.StoryResult(name: type.storyName, variant: variant.name)
        let started = ContinuousClock.now
        let story = type.init()
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
        let context = StoryContext(name: name, flags: flags, folder: folder, outputs: out, waits: waits)
        context.windowSize = flags.size ?? type.needs.window
        context.variant = variant
        Self.current = context

        var failed = false
        for step in story.steps() {
            if failed {
                result.steps.append(.init(label: step.label, outcome: .skip))
                continue
            }
            let stepStart = ContinuousClock.now
            do {
                if let timeout = step.timeout { context.timeout = timeout } else { context.timeout = .seconds(5) }
                try await step.run(context)
                result.steps.append(.init(label: step.label, outcome: .pass, ms: ms(since: stepStart)))
            } catch {
                failed = true
                result.steps.append(.init(label: step.label, outcome: .fail, ms: ms(since: stepStart), error: "\(error)"))
                result.files += evidence(context, step: result.steps.count)
            }
        }
        let log = out.appendingPathComponent("\(name).events.log")
        if (try? (context.eventLog + "\n").write(to: log, atomically: true, encoding: .utf8)) != nil {
            result.files.append(log.lastPathComponent)
        }
        context.finish()
        Self.current = nil
        if let window = context.window {
            window.close()
            // The next storyline may open the same folder: its window has to be gone, or opening
            // the folder would bring this one back.
            _ = try? await waits.until("the window to close", timeout: .seconds(5)) { !window.isVisible ? true : nil }
        }
        if !real {
            result.files += modes.end().map { "removed \($0.path)" }
        }
        result.ms = ms(since: started)
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
    private let standIns = CLIExecutable.standIns.value
    private let claudeStore = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]

    init() {
        StorylineSeams.backend = nil
        CLIExecutable.standIns.value = [:]
        unsetenv("CLAUDE_CONFIG_DIR")
    }

    func restore() {
        StorylineSeams.backend = backend
        CLIExecutable.standIns.value = standIns
        if let claudeStore { setenv("CLAUDE_CONFIG_DIR", claudeStore, 1) }
    }
}
