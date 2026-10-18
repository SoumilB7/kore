import Foundation
import Testing

@testable import KoreStorylines

@Suite("the storyline engine")
@MainActor
struct EngineTests {
    @Test func findsConcreteStorylinesButNotFamilies() {
        let names = Runner.discover().map(\.storyName)
        #expect(names.contains("ReplayDumpClaude"))
        #expect(names.contains("ReplayDumpCodex"))
        #expect(!names.contains("ResumeStoryline"))
        #expect(!names.contains("Storyline"))
    }

    @Test func picksByTagAndName() {
        let out = FileManager.default.temporaryDirectory
        let gate = Runner(selection: .init(tags: [.gate]), flags: RunFlags(), out: out).chosen().map { $0.0.storyName }
        #expect(gate.contains("ReplayDumpClaude"))
        let named = Runner(selection: .init(names: ["ReplayDumpCodex"]), flags: RunFlags(), out: out).chosen()
        #expect(named.map { $0.0.storyName } == ["ReplayDumpCodex"])
        let none = Runner(selection: .init(tags: ["no-such-tag"]), flags: RunFlags(), out: out).chosen()
        #expect(none.isEmpty)
    }

    @Test func readsTheRunnersArguments() {
        let options = StorylineHost.Options([
            "kore-storylines", "--tag", "gate,fork", "--size", "800x600", "--real-keys",
            "--replay", "claude|/tmp/demo|claude:abc;codex1|/tmp/probe|codex:def",
        ])
        #expect(options.selection.tags == [.gate, .fork])
        #expect(options.flags.size == CGSize(width: 800, height: 600))
        // Real keys only come with real input.
        #expect(!options.flags.realKeys)
        #expect(options.flags.replays["codex1"]?.session == "codex:def")
        #expect(options.flags.replays["claude"]?.folder.path == "/tmp/demo")
    }

    @Test func aFailedStepFailsItsStoryline() throws {
        var report = RunReport()
        report.stories = [
            .init(name: "A", variant: "", steps: [.init(label: "one", outcome: .pass)]),
            .init(name: "B", variant: "codex", steps: [
                .init(label: "one", outcome: .pass), .init(label: "two", outcome: .fail, error: "expected rows"),
                .init(label: "three", outcome: .skip),
            ]),
        ]
        #expect(!report.passed)
        #expect(report.text.contains("FAIL B [codex]"))
        #expect(report.text.contains("1 passed, 1 failed"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("storyline-report-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try report.write(to: folder)
        let decoded = try JSONDecoder.iso.decode(RunReport.self, from: Data(contentsOf: folder.appendingPathComponent("report.json")))
        #expect(decoded.stories[1].steps[1].error == "expected rows")
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
