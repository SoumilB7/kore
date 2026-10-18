import AppKit
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

    init(selection: Selection, flags: RunFlags, out: URL) {
        self.selection = selection
        self.flags = flags
        self.out = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
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
            .filter { selection.names.isEmpty || selection.names.contains($0.storyName) }
            .flatMap { story in story.variants.map { (story, $0) } }
            .filter { selection.provider == nil || $0.1.provider == nil || $0.1.provider == selection.provider }
    }

    // MARK: Running

    func run() async -> RunReport {
        var report = RunReport()
        for (story, variant) in chosen() {
            report.stories.append(await run(story, variant))
        }
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
        Self.current = nil
        context.window?.close()
        result.ms = ms(since: started)
        return result
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
