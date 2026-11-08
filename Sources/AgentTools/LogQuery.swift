import Foundation

/// `kore logs`: Kore's own logs (`~/Library/Logs/Kore`, `KoreLog`) read straight from their files,
/// so it works with the app closed. Every log's lines, merged by time, picked by age, chat, turn
/// and level. Foundation only, as the rest of `kore`.
package enum LogQuery {
    /// One line of a log: `<ISO time> <level> <event> key=value…` (and the older shape, a tab after
    /// the time and no level, read as info).
    package struct Line: Equatable, Sendable {
        package var at: Date
        package var level: String
        /// Which log: `ui`, `sessions`, `hosts`…
        package var log: String
        package var event: String
        package var fields: [(String, String)]
        /// The line as written, after the time.
        package var rest: String

        package static func == (a: Line, b: Line) -> Bool {
            a.at == b.at && a.level == b.level && a.log == b.log && a.event == b.event && a.rest == b.rest
                && a.fields.map { $0.0 + "=" + $0.1 } == b.fields.map { $0.0 + "=" + $0.1 }
        }

        package func field(_ key: String) -> String? { fields.first { $0.0 == key }?.1 }
    }

    package static let levels = ["debug", "info", "warn", "error"]

    /// What to show.
    package struct Filter: Sendable {
        package var since: Date?
        /// A chat id, or its first characters.
        package var chat: String?
        /// A turn's id: its own `turn` line and every line it carried `turn=` on.
        package var turn: String?
        /// The lowest level shown.
        package var level = "debug"
        /// Only these logs (`sessions`, `ui`…); empty for all.
        package var logs: Set<String> = []

        package init(since: Date? = nil, chat: String? = nil, turn: String? = nil, level: String = "debug", logs: Set<String> = []) {
            self.since = since
            self.chat = chat
            self.turn = turn
            self.level = level
            self.logs = logs
        }

        package func keeps(_ line: Line) -> Bool {
            if let since, line.at < since { return false }
            if !logs.isEmpty, !logs.contains(line.log) { return false }
            if (LogQuery.levels.firstIndex(of: line.level) ?? 1) < (LogQuery.levels.firstIndex(of: level) ?? 0) { return false }
            if let chat, !(line.field("chat")?.hasPrefix(chat) ?? false) { return false }
            if let turn, line.field("turn") != turn, !(line.event == "turn" && line.field("id") == turn) { return false }
            return true
        }
    }

    // MARK: Reading

    /// Kore's logs folder: `KORE_LOG_DIR`, else `~/Library/Logs/Kore`.
    package static func folder(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["KORE_LOG_DIR"], !["", "0", "off", "no"].contains(path.lowercased()) { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kore")
    }

    /// The folder's log files, each moved-aside `.1` before its live one.
    package static func files(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".log") || $0.hasSuffix(".log.1") }
            .sorted { ($0.hasSuffix(".1") ? 0 : 1, $0) < ($1.hasSuffix(".1") ? 0 : 1, $1) }
            .map { folder.appendingPathComponent($0) }
    }

    /// The log a file holds: `sessions` for `sessions.log` and `sessions.log.1`.
    package static func name(of file: URL) -> String {
        String(file.lastPathComponent.prefix { $0 != "." })
    }

    /// Every line `filter` keeps, from every log in `folder`, oldest first.
    package static func read(_ folder: URL, _ filter: Filter) -> [Line] {
        var lines: [Line] = []
        for file in files(in: folder) {
            let log = name(of: file)
            guard filter.logs.isEmpty || filter.logs.contains(log), let data = try? Data(contentsOf: file) else { continue }
            for text in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let line = parse(Substring(text), log: log), filter.keeps(line) { lines.append(line) }
            }
        }
        // Stable: lines at the same moment stay in their file's order.
        return lines.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    // MARK: Parsing

    package static func parse(_ text: Substring, log: String) -> Line? {
        guard let cut = text.firstIndex(where: { $0 == " " || $0 == "\t" }), let at = date(text[..<cut]) else { return nil }
        var rest = text[text.index(after: cut)...]
        var level = "info"
        if let space = rest.firstIndex(of: " "), levels.contains(String(rest[..<space])) {
            level = String(rest[..<space])
            rest = rest[rest.index(after: space)...]
        } else if levels.contains(String(rest)) {
            return Line(at: at, level: String(rest), log: log, event: "", fields: [], rest: "")
        }
        let (event, fields) = words(rest)
        return Line(at: at, level: level, log: log, event: event, fields: fields, rest: String(rest))
    }

    /// The event (every word before the first `key=value`) and the fields, unquoted.
    static func words(_ text: Substring) -> (String, [(String, String)]) {
        var event: [String] = []
        var fields: [(String, String)] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            let start = i
            while i < text.endIndex, text[i] != " ", text[i] != "=" { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "=", start < i else {
                // A bare word: the event's, before the fields start.
                while i < text.endIndex, text[i] != " " { i = text.index(after: i) }
                if fields.isEmpty { event.append(String(text[start..<i])) }
                continue
            }
            let key = String(text[start..<i])
            i = text.index(after: i)
            var value = ""
            if i < text.endIndex, text[i] == "\"" {
                i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\", text.index(after: i) < text.endIndex { i = text.index(after: i) }
                    value.append(text[i])
                    i = text.index(after: i)
                }
                if i < text.endIndex { i = text.index(after: i) }
            } else {
                while i < text.endIndex, text[i] != " " {
                    value.append(text[i])
                    i = text.index(after: i)
                }
            }
            fields.append((key, value))
        }
        return (event.joined(separator: " "), fields)
    }

    static func date(_ text: Substring) -> Date? {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return stamp.date(from: String(text))
    }

    /// `--since`: `90s`, `10m`, `2h`, `3d`, or an ISO time.
    package static func since(_ text: String, now: Date = Date()) -> Date? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last.flatMap({ units[$0] }), let count = Double(text.dropLast()), count >= 0 {
            return now.addingTimeInterval(-count * unit)
        }
        let stamp = ISO8601DateFormatter()
        return stamp.date(from: text) ?? date(Substring(text))
    }

    // MARK: Showing

    /// For a person: local time, level, log, then the line.
    package static func shown(_ line: Line, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .second, .nanosecond], from: line.at)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let time = String(format: "%02d-%02d %02d:%02d:%02d.%03d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        return "\(time) \(line.level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(line.log) \(line.rest)"
    }

    /// One JSON object: `ts`, `level`, `log`, `event`, then the fields.
    package static func json(_ line: Line) -> String {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: String] = [:]
        for (key, value) in line.fields { object[key] = value }
        object["ts"] = stamp.string(from: line.at)
        object["level"] = line.level
        object["log"] = line.log
        object["event"] = line.event
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
