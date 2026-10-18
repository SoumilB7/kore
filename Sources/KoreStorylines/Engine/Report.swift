import AppKit

/// What a run did, step by step: `report.json` and `report.txt` in the run's output folder.
package struct RunReport: Codable {
    package struct StepResult: Codable {
        package enum Outcome: String, Codable { case pass, fail, skip }
        package let label: String
        package var outcome: Outcome
        package var ms: Int = 0
        package var error: String? = nil
    }

    package struct StoryResult: Codable {
        package let name: String
        package let variant: String
        package var steps: [StepResult] = []
        package var ms: Int = 0
        /// Files written for this storyline: the failure snapshot, the event log, the rows.
        package var files: [String] = []
        package var passed: Bool { steps.allSatisfy { $0.outcome != .fail } }
        /// Not run at all (a `realinput` storyline without `--real-input`).
        package var skipped: Bool { steps.allSatisfy { $0.outcome == .skip } }
    }

    package var started = Date()
    package var stories: [StoryResult] = []
    package var passed: Bool { stories.allSatisfy(\.passed) }

    package var text: String {
        var lines: [String] = []
        for story in stories {
            let name = story.variant.isEmpty ? story.name : "\(story.name) [\(story.variant)]"
            lines.append("\(story.skipped ? "SKIP" : story.passed ? "PASS" : "FAIL") \(name)  \(story.ms) ms")
            for step in story.steps {
                let mark = switch step.outcome { case .pass: "  ✓"; case .fail: "  ✗"; case .skip: "  ·" }
                lines.append("\(mark) \(step.label)  \(step.ms) ms" + (step.error.map { "\n      \($0)" } ?? ""))
            }
            for file in story.files { lines.append("    → \(file)") }
        }
        let failed = stories.filter { !$0.passed }.count
        let skipped = stories.filter(\.skipped).count
        lines.append("\(stories.count - failed - skipped) passed, \(failed) failed" + (skipped > 0 ? ", \(skipped) skipped" : ""))
        return lines.joined(separator: "\n")
    }

    package func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent("report.json"))
        try (text + "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}

/// A window as it looks now, as PNG data (the window's frame view, title bar included).
@MainActor
func snapshot(_ window: NSWindow) -> Data? {
    guard let frame = window.contentView?.superview,
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
    else { return nil }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}
