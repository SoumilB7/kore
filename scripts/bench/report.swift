// The navigation bench's report (z-docs/phases/phase-11-navigation-p0/research-harness.md §4–5).
//
//   swift scripts/bench/report.swift <results-dir> <budgets.tsv> [--base <sha>] [--all]
//
// Reads every <sha>--<fixture>--<run>.ndjson in the folder (run 0 is the warm-up and is skipped),
// prints a table of each step's medians, checks the budgets and, with --base, compares each other
// build against that one. Budget rows listed in known-failures.tsv (next to budgets.tsv) print
// KNOWN instead of FAIL. Exits 1 on any FAIL, regression, or invalid or missing record.
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: report.swift <results-dir> <budgets.tsv> [--base <sha>] [--all]\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: args[1])
let budgetsURL = URL(fileURLWithPath: args[2])
let base = args.firstIndex(of: "--base").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let showAll = args.contains("--all")

typealias Record = [String: Any]

// MARK: Reading

struct Run { let sha: String; let fixture: String; let run: Int; var records: [Record] }

var runs: [Run] = []
var problems: [String] = []
let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
for name in files.sorted() where name.hasSuffix(".ndjson") {
    let parts = name.dropLast(".ndjson".count).components(separatedBy: "--")
    guard parts.count == 3, let number = Int(parts[2]) else { continue }
    guard number > 0 else { continue }
    let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    let records = text.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? Record
    }
    runs.append(Run(sha: parts[0], fixture: parts[1], run: number, records: records))
}
// A run that wrote no records, or fewer than its fixture's other runs, crashed or timed out.
for name in files.sorted() where name.hasSuffix(".log") {
    let parts = name.dropLast(".log".count).components(separatedBy: "--")
    guard parts.count == 3, let number = Int(parts[2]), number > 0 else { continue }
    if !runs.contains(where: { $0.sha == parts[0] && $0.fixture == parts[1] && $0.run == number }) {
        problems.append("\(parts[0]) \(parts[1]) run \(number): no records")
    }
}
let expected = Dictionary(grouping: runs, by: { "\($0.sha) \($0.fixture)" }).mapValues { $0.map(\.records.count).max() ?? 0 }
for run in runs {
    let full = expected["\(run.sha) \(run.fixture)"] ?? 0
    if run.records.count < full { problems.append("\(run.sha) \(run.fixture) run \(run.run): \(run.records.count) of \(full) records") }
    for record in run.records where record["valid"] as? Bool == false {
        problems.append("\(run.sha) \(run.fixture) run \(run.run) \(record["step"] ?? "?"): invalid, \(record["reason"] ?? "no reason")")
    }
}

func number(_ value: Any?) -> Double? {
    switch value {
    case let value as Double: value
    case let value as Int: Double(value)
    case let value as Bool: value ? 1 : 0
    case let value as NSNumber: value.doubleValue
    default: nil
    }
}

/// The record's own numbers plus the derived ones the budgets use.
func metrics(_ record: Record, ready: Record?) -> [String: Double] {
    var out: [String: Double] = [:]
    for (key, value) in record { if let value = number(value), key != "run", key != "v" { out[key] = value } }
    if let px = out["px"], px > 0 {
        if let missed = out["missed"] { out["missed_per_10kpx"] = missed / px * 10_000 }
        if let cpu = out["cpu_s"] { out["cpu_s_per_10kpx"] = cpu / px * 10_000 }
    }
    if let peak = out["mem_peak_mb"], let settled = out["mem_settled_mb"] { out["peak_over_settled_mb"] = peak - settled }
    if let start = out["mem_start_mb"], let settled = out["mem_settled_mb"] { out["mem_delta_mb"] = settled - start }
    let counts = out.filter { $0.key.hasSuffix("_n") }.values
    if let actions = counts.max(), actions > 0, let cpu = out["cpu_s"] { out["cpu_s_per_action"] = cpu / actions }
    if let settled = out["mem_settled_mb"], let readySettled = ready.flatMap({ number($0["mem_settled_mb"]) }) {
        out["over_ready_mb"] = settled - readySettled
    }
    return out
}

/// (sha, fixture, step) → metric → one value per run.
struct Key: Hashable, Comparable {
    let sha: String, fixture: String, index: Int, step: String
    static func < (a: Key, b: Key) -> Bool { (a.sha, a.fixture, a.index) < (b.sha, b.fixture, b.index) }
}
var values: [Key: [String: [Double]]] = [:]
for run in runs {
    let ready = run.records.first { $0["step"] as? String == "ready" }
    for (index, record) in run.records.enumerated() {
        guard let step = record["step"] as? String, step != "env" else { continue }
        let key = Key(sha: run.sha, fixture: run.fixture, index: index, step: step)
        for (metric, value) in metrics(record, ready: ready) { values[key, default: [:]][metric, default: []].append(value) }
    }
}

func quantile(_ list: [Double], _ q: Double) -> Double {
    let sorted = list.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
}
func format(_ value: Double?) -> String {
    guard let value else { return "–" }
    if value == value.rounded(), abs(value) < 100_000 { return String(Int(value)) }
    return abs(value) < 1 ? String(format: "%.3f", value) : String(format: "%.1f", value)
}

// MARK: Table

/// The number a step is about, shown first.
func headline(_ step: String) -> String? {
    switch step.split(separator: ":").first.map(String.init) ?? step {
    case "ready": "open_kore_ms"
    case "switch": "tab_switch_ms_p95"
    case "scroll": "px"
    case let s where s.hasPrefix("fling"): "px"
    case "earlierconv": "earlier_conv_ms"
    case let s where s.hasPrefix("earlier"): "earlier_ms_p95"
    case let s where s.hasPrefix("fold"): "fold_ms_p95"
    case "send": "send_row_ms_p95"
    default: nil
    }
}

let columns = ["missed", "over33", "worst_ms", "hitch_ms_per_s", "mem_peak_mb", "mem_settled_mb", "cpu_s", "cpu_peak_pct", "cli_cpu_s"]
let shas = Array(Set(values.keys.map(\.sha))).sorted { a, b in a == base ? false : b == base ? true : a < b }
print("# Navigation bench")
print("")
print("Medians over \(Set(runs.map(\.run)).count) runs; worst_ms and over33 show the max. Memory in MB, CPU in seconds and % of one core.")
for sha in shas {
    for fixture in Array(Set(values.keys.filter { $0.sha == sha }.map(\.fixture))).sorted() {
        print("\n## \(sha) · \(fixture)\n")
        print("| step | value | " + columns.joined(separator: " | ") + " |")
        print("|---|---:|" + String(repeating: "---:|", count: columns.count))
        for key in values.keys.filter({ $0.sha == sha && $0.fixture == fixture }).sorted() {
            let row = values[key]!
            let value = headline(key.step).flatMap { row[$0] }.map { "\(format(quantile($0, 0.5)))" } ?? ""
            let cells = columns.map { column -> String in
                guard let list = row[column] else { return "–" }
                return format(column == "worst_ms" || column == "over33" ? list.max() : quantile(list, 0.5))
            }
            print("| \(key.step) | \(value) | " + cells.joined(separator: " | ") + " |")
        }
    }
}

// MARK: Budgets

func matches(_ pattern: String, _ text: String) -> Bool {
    let negated = pattern.hasPrefix("!")
    let alternatives = (negated ? String(pattern.dropFirst()) : pattern).split(separator: "|").map(String.init)
    let hit = alternatives.contains { fnmatch($0, text, 0) == 0 }
    return negated ? !hit : hit
}

struct Budget { let fixture, steps, metric, combine: String; let limit: Double; let note: String }
let budgets: [Budget] = ((try? String(contentsOf: budgetsURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
    guard !line.hasPrefix("#") else { return nil }
    let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard cells.count >= 5, let limit = Double(cells[4]) else { return nil }
    return Budget(fixture: cells[0], steps: cells[1], metric: cells[2], combine: cells[3], limit: limit, note: cells.count > 5 ? cells[5] : "")
}
/// fixture  step  metric  note — failures today's main already has.
let known: [(fixture: String, step: String, metric: String)] =
    ((try? String(contentsOf: budgetsURL.deletingLastPathComponent().appendingPathComponent("known-failures.tsv"), encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { line in
        guard !line.hasPrefix("#") else { return nil }
        let cells = line.split(separator: "\t").map(String.init)
        return cells.count >= 3 ? (cells[0], cells[1], cells[2]) : nil
    }

var failures = 0
var knownCount = 0
var passes = 0
var lines: [String] = []
for budget in budgets {
    for key in values.keys.sorted() where matches(budget.fixture, key.fixture) && matches(budget.steps, key.step) {
        guard let list = values[key]?[budget.metric], !list.isEmpty else { continue }
        let combined = budget.combine == "max" ? list.max()! : quantile(list, 0.5)
        let ok = combined <= budget.limit + 1e-9
        let isKnown = known.contains { matches($0.fixture, key.fixture) && matches($0.step, key.step) && $0.metric == budget.metric }
        let verdict = ok ? "PASS" : isKnown ? "KNOWN" : "FAIL"
        if ok { passes += 1 } else if isKnown { knownCount += 1 } else { failures += 1 }
        guard !ok || showAll else { continue }
        lines.append("| \(verdict) | \(key.sha) | \(key.fixture) | \(key.step) | \(budget.metric) | \(format(quantile(list, 0.5))) | \(format(quantile(list, 0.95))) | \(format(list.max())) | \(budget.combine) ≤ \(format(budget.limit)) | \(budget.note) |")
    }
}
print("\n## Budgets: \(passes) pass, \(failures) fail, \(knownCount) known\n")
if !lines.isEmpty {
    print("| verdict | build | fixture | step | metric | p50 | p95 | max | budget | note |")
    print("|---|---|---|---|---|---:|---:|---:|---|---|")
    lines.forEach { print($0) }
}

// MARK: Against the base build

var regressions = 0
if let base, shas.contains(base) {
    /// metric → (relative, absolute floor), or nil to report a WARN only past +20%.
    func rule(_ metric: String) -> (Double, Double, warnOnly: Bool)? {
        if metric.hasPrefix("cli_") { return (0.20, 0, true) }
        if metric.hasSuffix("_ms_p95") || ["open_kore_ms", "earlier_conv_ms"].contains(metric) { return (0.10, 3, false) }
        if ["mem_peak_mb", "mem_settled_mb"].contains(metric) { return (0.05, 1, false) }
        if metric == "cpu_s" { return (0.05, 0.02, false) }
        if metric == "cpu_peak_pct" { return (0.05, 5, false) }
        return nil
    }
    var rows: [String] = []
    for key in values.keys.sorted() where key.sha != base {
        let baseKey = Key(sha: base, fixture: key.fixture, index: key.index, step: key.step)
        guard let mine = values[key], let theirs = values[baseKey] else { continue }
        for metric in mine.keys.sorted() {
            guard let a = theirs[metric], let b = mine[metric] else { continue }
            if ["over33", "stalls", "late_jumps"].contains(metric), b.max()! > 0, a.max()! == 0 {
                regressions += 1
                rows.append("| FAIL | \(key.fixture) | \(key.step) | \(metric) | 0 | \(format(b.max())) | new |")
                continue
            }
            guard let (relative, floor, warnOnly) = rule(metric) else { continue }
            let was = quantile(a, 0.5), now = quantile(b, 0.5)
            guard now > was * (1 + relative), now - was > floor else { continue }
            if !warnOnly { regressions += 1 }
            rows.append("| \(warnOnly ? "WARN" : "FAIL") | \(key.fixture) | \(key.step) | \(metric) | \(format(was)) | \(format(now)) | +\(Int(((now / max(was, 1e-9)) - 1) * 100))% |")
        }
    }
    print("\n## Against \(base): \(regressions) regressions\n")
    if !rows.isEmpty {
        print("| verdict | fixture | step | metric | \(base) | branch | change |")
        print("|---|---|---|---|---:|---:|---:|")
        rows.forEach { print($0) }
    }
}

if !problems.isEmpty {
    print("\n## Invalid or missing (\(problems.count))\n")
    problems.forEach { print("- \($0)") }
}
exit(failures + regressions + problems.count > 0 ? 1 : 0)
