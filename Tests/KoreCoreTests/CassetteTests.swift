import Foundation
import Testing

@testable import KoreCore

@Suite("cassettes: scrubbing, reading and recording", .serialized)
struct CassetteTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func scrubsTheWorkFolderInEveryFormACLIPrints() {
        let paths = CassettePaths(work: URL(fileURLWithPath: "/private/tmp/run-1/folder"), home: home)
        #expect(paths.scrub(#"{"cwd":"/private/tmp/run-1/folder"}"#) == #"{"cwd":"/WORK"}"#)
        #expect(paths.scrub(#"{"cwd":"/tmp/run-1/folder/a.swift"}"#) == #"{"cwd":"/WORK/a.swift"}"#)
        #expect(
            paths.scrub(#"{"auto":"/Users/someone/.claude/projects/-private-tmp-run-1-folder/memory/"}"#)
                == #"{"auto":"/HOME/.claude/projects/-WORK/memory/"}"#)
    }

    @Test func prefersTheWorkFolderOverHomeForAFolderUnderHome() {
        let paths = CassettePaths(work: URL(fileURLWithPath: "/Users/someone/code/app"), home: home)
        #expect(paths.scrub("/Users/someone/code/app/x and /Users/someone/.codex") == "/WORK/x and /CODEX_HOME")
    }

    @Test func scrubsAndRestoresCodexsHome() {
        let paths = CassettePaths(work: URL(fileURLWithPath: "/w"), codexHome: URL(fileURLWithPath: "/private/tmp/run/codex-home"), home: home)
        #expect(paths.scrub(#"{"codexHome":"/tmp/run/codex-home","path":"/private/tmp/run/codex-home/sessions/r.jsonl"}"#)
            == #"{"codexHome":"/CODEX_HOME","path":"/CODEX_HOME/sessions/r.jsonl"}"#)
        let real = CassettePaths(work: URL(fileURLWithPath: "/w"), home: home)
        #expect(real.restore("/CODEX_HOME/sessions") == "/Users/someone/.codex/sessions")
    }

    @Test func restoresThisRunsPaths() {
        let paths = CassettePaths(work: URL(fileURLWithPath: "/private/tmp/run-2/folder"), home: home)
        #expect(paths.restore(#"{"cwd":"/WORK","dir":"-WORK","home":"/HOME"}"#)
            == #"{"cwd":"/private/tmp/run-2/folder","dir":"-private-tmp-run-2-folder","home":"/Users/someone"}"#)
        #expect(paths.restore("nothing to do") == "nothing to do")
    }

    @Test func scrubsAccountDetailsAndKeepsTheRestOfTheLine() {
        let paths = CassettePaths(work: URL(fileURLWithPath: "/w"), home: home)
        let line = #"{"account":{"email":"a@b.c","organization":"A's \"Org\"","subscriptionType":"Max"},"pid":1}"#
        #expect(paths.scrub(line)
            == #"{"account":{"email":"SCRUBBED","organization":"SCRUBBED","subscriptionType":"SCRUBBED"},"pid":1}"#)
        #expect(paths.scrub(#"{"params":{"planType": "go","balance":"25.0"}}"#)
            == #"{"params":{"planType": "SCRUBBED","balance":"SCRUBBED"}}"#)
    }

    @Test func readsProcessesAndTheirLines() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
            {"cassette":1,"proc":0,"cli":"codex","args":["app-server"],"cwd":"/WORK"}
            {"t":0.01,"dir":"in","p":0,"line":"{\\"id\\":1,\\"method\\":\\"initialize\\"}"}
            {"t":0.20,"dir":"out","p":0,"line":"{\\"id\\":1,\\"result\\":{}}"}
            {"cassette":1,"proc":1,"cli":"codex","args":["app-server"],"cwd":"/WORK"}
            {"t":0.05,"dir":"exit","p":1,"status":0}
            {"t":0.90,"dir":"exit","p":0,"status":143}

            """.write(to: file, atomically: true, encoding: .utf8)
        let cassette = try KoreCore.Cassette(contentsOf: file)
        #expect(cassette.processes.map(\.index) == [0, 1])
        #expect(cassette.processes[0].cli == "codex" && cassette.processes[0].args == ["app-server"])
        #expect(cassette.processes[0].lines.map(\.dir) == [.in, .out, .exit])
        #expect(cassette.processes[0].lines[1].text == #"{"id":1,"result":{}}"#)
        #expect(cassette.processes[0].lines[2].status == 143)
        #expect(cassette.processes[1].lines.map(\.dir) == [.exit])
    }

    @Test func recordsAProcessThroughStdioProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rec.jsonl")
        StdioProcess.recorder.value = try CassetteRecorder(url: file, work: dir, model: "haiku")
        defer { StdioProcess.recorder.value = nil }

        // Echoes one stdin line back with the folder in it, writes a stderr line, then exits 3.
        let script = #"read line; printf '{"got":%s,"cwd":"%s"}\n' "$line" "$(pwd -P)"; echo oops >&2; exit 3"#
        let io = try StdioProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], cwd: dir,
            environment: ProcessInfo.processInfo.environment)
        try io.write(["hello": "world"])
        var status: Int32?
        for await output in io.output { if case .exited(let s) = output { status = s } }
        #expect(status == 3)
        StdioProcess.recorder.value = nil

        // The recorder is process-wide: CLIs other tests start meanwhile land in this file too,
        // other `sh` ones among them under load. This one is told by its own script.
        let cassette = try KoreCore.Cassette(contentsOf: file)
        let process = try #require(cassette.processes.first { $0.cli == "sh" && $0.args.last == script })
        let lines = process.lines
        #expect(lines.first { $0.dir == .in }?.text == #"{"hello":"world"}"#)
        #expect(lines.first { $0.dir == .out }?.text == #"{"got":{"hello":"world"},"cwd":"/WORK"}"#)
        #expect(lines.contains { $0.dir == .err && $0.text == "oops" })
        #expect(lines.last?.dir == .exit && lines.last?.status == 3)
        let header = try #require(
            String(contentsOf: file, encoding: .utf8).split(separator: "\n").first { line in
                let json = try? JSONValue.parse(Data(line.utf8))
                return json?["dir"] == nil && json?["proc"]?.int == process.index
            })
        #expect(header.contains(#""cwd":"/WORK""#) && header.contains(#""model":"haiku""#) && header.contains(#""cassette":1"#))
    }
}
