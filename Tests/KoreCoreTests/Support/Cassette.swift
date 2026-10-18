import Foundation
import KoreCore

/// A recorded CLI session (phase 12's cassette format, `Tests/Fixtures/cassettes`): a header line,
/// then one `{t, dir, p, line}` per raw line on the wire ("in" to the CLI, "out", "err"), and an
/// "exit" line.
struct Cassette {
    struct Line {
        let t: Double
        let dir: String
        let raw: String
        var json: JSONValue? { try? JSONValue.parse(Data(raw.utf8)) }
    }

    let header: JSONValue
    let lines: [Line]

    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cassettes")

    init(_ name: String) throws {
        let text = try String(contentsOf: Self.folder.appendingPathComponent(name + ".jsonl"), encoding: .utf8)
        var rows = text.split(separator: "\n").map { try? JSONValue.parse(Data($0.utf8)) }
        header = (rows.isEmpty ? nil : rows.removeFirst()) ?? .null
        lines = rows.compactMap { row in
            guard let row, let dir = row["dir"]?.string, let raw = row["line"]?.string else { return nil }
            return Line(t: row["t"]?.double ?? 0, dir: dir, raw: raw)
        }
    }

    var out: [JSONValue] { lines.filter { $0.dir == "out" }.compactMap(\.json) }
    var sent: [JSONValue] { lines.filter { $0.dir == "in" }.compactMap(\.json) }
}
