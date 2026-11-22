import AppKit
import KoreUI
import src

/// What chats nobody sees cost while they stream: eight tabs with long histories, seven of them
/// answering behind the one shown. Main-thread busy time, stalls and rebuilds (shown and hidden)
/// over ten seconds go to `nav.notes`; nothing is asserted, so a change and the main it starts
/// from are measured by the same code (run it under load to see what the owner's Mac sees).
final class HiddenStreamCost: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var seesOcclusion: Bool { true }

    static let chats = 8

    /// A long history: 120 turns, each a message and a markdown answer.
    static func history(_ chat: Int) -> [ChatEvent] {
        (1...120).flatMap { n -> [ChatEvent] in
            let turn = "c\(chat)-t\(n)"
            return [
                .userMessage(text: "chat \(chat) message \(n)", attachments: [], id: "c\(chat)-m\(n)"),
                .turnStarted(turn, origin: .user, at: Date()),
                .text("c\(chat)-a\(n)", .answer, NavCost.answer(chat, turn: n % 4 + 1)),
                .turnFinished(turn, .completed, duration: nil),
            ]
        }
    }

    /// The history, then one long answer streamed for each send.
    static func script(_ chat: Int) -> CLIScript {
        let long = (1...40).map { NavCost.answer(chat, turn: $0 % 4 + 1) }.joined(separator: "\n\n")
        return CLIScript(start: [.controls(), .event(.replayed(history(chat)))], turns: [[.startTurn, .stream(.answer, long), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        var steps: [any Step] = [OpenFolder(), Do("stream at 60 deltas a second") { _ in ScriptedWorld.shared.rate = 60 }]
        for chat in 1...Self.chats {
            steps += [UseScript(Self.script(chat)), chat == 1 ? StartChat("claude") : OpenTabs(1), Send("go \(chat)")]
        }
        steps += [
            Do("show the first tab") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                workspace.storySelect(tabAt: 0)
            },
            MeasureHiddenStreams(seconds: 10),
            MeasureSwitchToStreamed(),
        ]
        return steps
    }
}

/// Main-thread busy time (each run-loop pass from waking to waiting again), its stalls, and the
/// transcripts' rebuilds, for `seconds` while the chats stream.
struct MeasureHiddenStreams: Step {
    let seconds: Int
    var label: String { "Measure \(seconds) s of hidden streaming" }
    var timeout: Duration? { .seconds(seconds + 60) }

    @MainActor
    final class Busy {
        var total = 0.0
        var passes = 0
        var over250 = 0
        var over2s = 0
        var worst = 0.0
        private var woke: CFAbsoluteTime?
        private var observer: CFRunLoopObserver?

        func start() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if activity == .afterWaiting {
                        self.woke = now
                    } else if let woke = self.woke {
                        let ms = (now - woke) * 1000
                        self.total += ms
                        self.passes += 1
                        if ms > 250 { self.over250 += 1 }
                        if ms > 2000 { self.over2s += 1 }
                        self.worst = max(self.worst, ms)
                        self.woke = nil
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
    }

    func run(_ story: StoryContext) async throws {
        let busy = Busy()
        RebuildCount.reset()
        RebuildCount.on = true
        busy.start()
        try await Task.sleep(for: .seconds(seconds))
        busy.stop()
        RebuildCount.on = false
        let states = (story.app.workspace?.tabs ?? []).compactMap { tab in tab.chat.map { "\($0.storyTranscript.endWhy.components(separatedBy: "; ").last ?? ""), running \($0.status.isRunning)" } }
        let s = Double(seconds)
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let line = "\(story.name) \(HiddenStreamCost.chats) chats, \(seconds) s: main busy \(f(busy.total / s)) ms/s (\(busy.passes) passes, worst \(f(busy.worst)) ms, over 250 ms \(busy.over250), over 2 s \(busy.over2s)); "
            + "rebuilds shown \(RebuildCount.shown) (\(f(RebuildCount.shownMs)) ms), hidden \(RebuildCount.hidden) (\(f(RebuildCount.hiddenMs)) ms); tabs: \(states.joined(separator: " | "))\n"
        print(line, terminator: "")
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The switch to a chat that streamed with nobody seeing it: what its one catch-up costs (the
/// rows built as it shows), and the time to its first drawn frame.
struct MeasureSwitchToStreamed: Step {
    var label: String { "Measure the switch to a chat that streamed unseen" }
    var timeout: Duration? { .seconds(60) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var parts: [String] = []
        for index in [1, 2, 3] {
            RebuildCount.reset()
            RebuildCount.on = true
            let (sync, settled) = await DevNavProbe.switchTo(workspace, index: index)
            RebuildCount.on = false
            parts.append("tab \(index + 1): sync \(f(sync)) ms, first still frame \(settled.map(f) ?? "-") ms, rebuilds \(RebuildCount.shown + RebuildCount.hidden) (\(f(RebuildCount.shownMs + RebuildCount.hiddenMs)) ms)")
        }
        let line = "\(story.name) switch to a streamed chat: " + parts.joined(separator: "; ") + "\n"
        print(line, terminator: "")
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
