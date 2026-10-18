import Foundation
import KoreCore

// Plays a recorded CLI session (a cassette, `Cassette`) in place of `claude` or `codex`, so Kore's
// sessions, translators and process handling run end to end with no model (phase 12's process
// mode). Kore launches it through `CLIExecutable.standIns` with the real CLI's arguments, in the
// chat's folder, and this environment:
//
//   KORE_FAKE_AS=claude|codex      which CLI it is
//   KORE_FAKE_CASSETTE=<path>      the cassette
//   KORE_FAKE_CLAIMS=<path>        a file shared by every process of one run: which recorded
//                                  processes are taken (a run can launch several CLIs)
//   KORE_FAKE_PACE=<x>             0 (the default): output as fast as Kore reads it; 1: at the
//                                  recorded times
//
// A recorded process plays in order. Its output goes out at once; at each run of recorded input
// lines it waits for Kore's, matched loosely (`FakeMatch`) and in any order within the run. Ids
// Kore makes up are learned from each match and put in place of the recorded ones in what
// follows (`IdMap`). A line Kore sends that the cassette doesn't expect ends the process with
// exit status 2 and says why on stderr.

let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kore-fake-cli: \(message)\n".utf8))
    exit(2)
}

guard let cli = environment["KORE_FAKE_AS"], let cassettePath = environment["KORE_FAKE_CASSETTE"] else {
    fail("set KORE_FAKE_AS (claude or codex) and KORE_FAKE_CASSETTE")
}
let cassette: Cassette
do { cassette = try Cassette(contentsOf: URL(fileURLWithPath: cassettePath)) } catch { fail("can't read \(cassettePath): \(error)") }
let paths = CassettePaths(
    work: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    codexHome: environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) })
let pace = Double(environment["KORE_FAKE_PACE"] ?? "") ?? 0
let arguments = Array(CommandLine.arguments.dropFirst())

// Recorded processes of this CLI started with these arguments, in recorded order.
let sameCLI = cassette.processes.filter { ($0.cli ?? cli) == cli }
let candidates = sameCLI.filter { FakeMatch.sameArguments($0.args.map(paths.restore), arguments) }
let claims = Claims(path: environment["KORE_FAKE_CLAIMS"])
guard let first = claims.take(from: candidates.map(\.index)), var process = candidates.first(where: { $0.index == first }) else {
    fail("no \(cli) process left in \(cassettePath) started with \(arguments) (recorded: \(sameCLI.map(\.args)))")
}

// Kore's stdin, a line at a time.
let input = LineQueue()
Thread.detachNewThread {
    var splitter = LineSplitter()
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { break }
        for line in splitter.feed(data) { input.push(String(decoding: line, as: UTF8.self)) }
    }
    if let last = splitter.finish() { input.push(String(decoding: last, as: UTF8.self)) }
    input.close()
}

/// Another free recorded process that went exactly like this one up to `position` and expects
/// `live` there: two `codex app-server`s (a chat's and the history list's) start the same, and
/// which one Kore launched first isn't fixed.
func alternative(at position: Int, for live: String) -> Cassette.Process? {
    let played = process.lines[..<position]
    return candidates.first { other in
        other.index != process.index && other.lines.count > position
            && zip(other.lines[..<position], played).allSatisfy { $0.dir == $1.dir && $0.text == $1.text }
            && other.lines[position...].prefix { $0.dir == .in }.contains {
                FakeMatch.matches(recorded: paths.restore($0.text), live: live)
            }
            && claims.move(from: process.index, to: other.index)
    }
}

var ids = IdMap()
let start = Date()
var position = 0

while position < process.lines.count {
    let line = process.lines[position]
    switch line.dir {
    case .out, .err:
        if pace > 0 {
            let wait = line.t * pace - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        let handle = line.dir == .out ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data((ids.rewrite(paths.restore(line.text)) + "\n").utf8))
        position += 1
    case .exit:
        exit(line.status ?? 0)
    case .in:
        var expected = Array(process.lines[position...].prefix { $0.dir == .in })
        let run = expected.count
        while !expected.isEmpty {
            // Kore closed stdin: the CLI would have ended.
            guard let live = input.pop() else { exit(0) }
            if let hit = expected.firstIndex(where: { FakeMatch.matches(recorded: paths.restore($0.text), live: live) }) {
                ids.learn(recorded: paths.restore(expected[hit].text), live: live)
                expected.remove(at: hit)
            } else if expected.count == run, let other = alternative(at: position, for: live) {
                process = other
                expected = Array(process.lines[position...].prefix { $0.dir == .in })
                let hit = expected.firstIndex { FakeMatch.matches(recorded: paths.restore($0.text), live: live) }!
                ids.learn(recorded: paths.restore(expected[hit].text), live: live)
                expected.remove(at: hit)
            } else {
                // What the lines ask for first (their key order varies), then the line itself.
                fail(
                    "\(cassettePath), process \(process.index), line \(position + 1): Kore sent "
                        + "[\(FakeMatch.signature(of: live))]; the cassette expects "
                        + "\(expected.map { "[\(FakeMatch.signature(of: paths.restore($0.text)))]" }). Kore's line: \(live.prefix(400))")
            }
        }
        position += run
    }
}
// The recording has no exit line: end when Kore closes stdin.
while input.pop() != nil {}
exit(0)
