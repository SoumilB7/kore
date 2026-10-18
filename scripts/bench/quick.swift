// The quick bench's summary: the few numbers a hypothesis is judged by, per build and fixture.
//
//   swift scripts/bench/quick.swift <results-dir> [--base <sha>]
//
// Over the scroll steps of every measured run (run 0 is the warm-up): frames over 33 ms per
// 10k px scrolled, the frame time p95 (median over runs of each run's worst scroll step), and
// rows entering view on the main thread (row_enter_ms_p95) when the records have it. Over all
// steps: peak memory (median over runs of each run's peak). With --base, each other build's
// change from that one.
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: quick.swift <results-dir> [--base <sha>]\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: args[1])
let base = args.firstIndex(of: "--base").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

typealias Record = [String: Any]
func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
func median(_ list: [Double]) -> Double? {
    guard !list.isEmpty else { return nil }
    let sorted = list.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

struct Key: Hashable, Comparable {
    let sha: String, fixture: String
    static func < (a: Key, b: Key) -> Bool { (a.fixture, a.sha) < (b.fixture, b.sha) }
}
struct PerRun { var over33 = 0.0, px = 0.0, p95: Double?, enter: Double?, mem: Double?, invalid: [String] = [] }

var runs: [Key: [PerRun]] = [:]
let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
for name in files.sorted() where name.hasSuffix(".ndjson") {
    let parts = name.dropLast(".ndjson".count).components(separatedBy: "--")
    guard parts.count == 3, let n = Int(parts[2]), n > 0 else { continue }
    let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    var run = PerRun()
    for line in text.split(separator: "\n") {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? Record,
            let step = record["step"] as? String, step != "env"
        else { continue }
        if record["valid"] as? Bool == false { run.invalid.append("\(step): \(record["reason"] ?? "?")") }
        if let mem = number(record["mem_peak_mb"]) { run.mem = max(run.mem ?? 0, mem) }
        guard step.hasPrefix("scroll") || step.hasPrefix("fling") else { continue }
        run.over33 += number(record["over33"]) ?? 0
        run.px += number(record["px"]) ?? 0
        if let p95 = number(record["frame_p95_ms"]) { run.p95 = max(run.p95 ?? 0, p95) }
        if let enter = number(record["row_enter_ms_p95"]) { run.enter = max(run.enter ?? 0, enter) }
    }
    runs[Key(sha: parts[0], fixture: parts[1]), default: []].append(run)
}

struct Summary { var stalls: Double?, p95: Double?, enter: Double?, mem: Double?, runs: Int, invalid: [String] }
func summary(_ list: [PerRun]) -> Summary {
    Summary(
        stalls: median(list.filter { $0.px > 0 }.map { $0.over33 / $0.px * 10_000 }),
        p95: median(list.compactMap(\.p95)), enter: median(list.compactMap(\.enter)),
        mem: median(list.compactMap(\.mem)), runs: list.count, invalid: list.flatMap(\.invalid))
}
func format(_ value: Double?, _ digits: Int = 1) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "–" }
func change(_ now: Double?, _ was: Double?) -> String {
    guard let now, let was else { return "" }
    if was == 0 { return now == 0 ? " (=)" : " (was 0)" }
    let pct = (now / was - 1) * 100
    return String(format: " (%+.0f%%)", pct)
}

print("| build | fixture | runs | stalls >33ms /10k px | frame p95 ms (scroll) | rows entering ms p95 | peak MB |")
print("|---|---|---|---|---|---|---|")
var invalid: [String] = []
for key in runs.keys.sorted() {
    let s = summary(runs[key]!)
    let b = base.flatMap { base in key.sha == base ? nil : runs[Key(sha: base, fixture: key.fixture)].map(summary) }
    print("| \(key.sha) | \(key.fixture) | \(s.runs) | \(format(s.stalls))\(change(s.stalls, b?.stalls)) | \(format(s.p95))\(change(s.p95, b?.p95)) | \(format(s.enter, 2))\(change(s.enter, b?.enter)) | \(format(s.mem, 0))\(change(s.mem, b?.mem)) |")
    invalid += s.invalid.map { "\(key.sha) \(key.fixture) \($0)" }
}
if !invalid.isEmpty {
    print("\ninvalid records (numbers above include them):")
    for line in Set(invalid).sorted() { print("- \(line)") }
}
