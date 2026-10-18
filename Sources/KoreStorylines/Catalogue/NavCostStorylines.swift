import AppKit
import KoreUI

/// Navigation numbers, in-process: building answer rows offscreen, switching between three
/// chats of long markdown answers, and scrolling one from end to top and back. Nothing is
/// asserted; the numbers go to `nav.notes` in the run's folder, so a change and the main it
/// starts from are measured by the same code.
final class NavCost: Storyline {
    override class var tags: Set<Tag> { [.chat] }

    /// Six typical answer blocks: a heading, paragraphs, a list, code and a table each.
    static func answer(_ chat: Int, turn: Int) -> String {
        (0..<6).map { DevNavProbe.sample(chat * 100 + turn * 10 + $0) }.joined(separator: "\n\n")
    }

    static func script(_ chat: Int) -> CLIScript {
        CLIScript(turns: (1...4).map { turn in [.startTurn, .stream(.answer, answer(chat, turn: turn), chunk: 4000), .finishTurn(.completed)] })
    }

    static func chat(_ n: Int) -> [any Step] {
        [UseScript(script(n)), StartChat("claude")] + (1...4).flatMap { turn -> [any Step] in
            [Send("chat \(n), turn \(turn)"), TurnFinished(turn)]
        }
    }

    override func steps() -> [any Step] {
        [OpenFolder()] + Self.chat(1) + Self.chat(2) + Self.chat(3) + [WaitIdle(), MeasureNav(), MeasureSelectedScroll()]
    }
}

struct MeasureNav: Step {
    var label: String { "Measure row building, tab switching and scrolling" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        var lines: [String] = []
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int((Double(v.count - 1) * 0.95).rounded()))] }

        // Rows: 40 answers, a warm-up, then 12 builds.
        _ = DevNavProbe.buildRows(40)
        let builds = (0..<12).map { _ in ms(DevNavProbe.buildRows(40)) }
        lines.append("rows: 40 answers median \(f(median(builds))) ms (\(String(format: "%.2f", median(builds) / 40)) ms/row), min \(f(builds.min() ?? 0)), max \(f(builds.max() ?? 0))")

        // Tabs: a warm-up lap (each chat shown once), then 30 switches.
        _ = await DevNavProbe.switchTabs(workspace, rounds: 3)
        let tabs = await DevNavProbe.switchTabs(workspace, rounds: 30)
        lines.append("switch: \(tabs.ms.count) switches median \(f(median(tabs.ms))) ms, p95 \(f(p95(tabs.ms))), max \(f(tabs.ms.max() ?? 0)); frames \(tabs.frames), over 33 ms \(tabs.over33), frame p95 \(f(tabs.p95)) ms")

        // Scrolling: end to top and back, twice.
        for round in 1...2 {
            let s = await DevNavProbe.scroll(workspace)
            lines.append("scroll \(round): \(Int(s.px)) px, frames \(s.frames), over 33 ms \(s.over33), frame p95 \(f(s.p95)) ms, worst \(f(s.worst)) ms")
        }
        let text = lines.map { "\(story.name) \($0)" }.joined(separator: "\n") + "\n"
        let url = story.outputs.appendingPathComponent("nav.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
