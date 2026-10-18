import Foundation

/// A CLI session as it went over the wire: what Kore wrote to each CLI process's stdin, what the
/// process wrote back, and how it ended (phase 12, `cli-modes.md`). `kore-fake-cli` plays one
/// back in place of the CLI; core tests read its "out" lines.
///
/// One JSONL file. A header line opens each process the session launched:
///   {"cassette":1,"proc":0,"cli":"claude","args":[…],"cwd":"/WORK","model":"haiku","recorded":"2026-10-21"}
/// then one line per raw line on the wire, in order, from the CLI's side ("in" is its stdin):
///   {"t":0.412,"dir":"in"|"out"|"err","p":0,"line":"<the line, unparsed>"}
///   {"t":3.900,"dir":"exit","p":0,"status":0}
/// `t` is seconds since that process started. Paths are scrubbed (`CassettePaths`) and account
/// details replaced by "SCRUBBED"; ids are kept, since a player maps them to the live ones.
package struct Cassette: Sendable {
    package enum Direction: String, Sendable {
        case `in`, out, err, exit
    }

    package struct Line: Sendable {
        package let t: Double
        package let dir: Direction
        package let text: String
        /// For `.exit`.
        package let status: Int32?
    }

    package struct Process: Sendable {
        package let index: Int
        package let cli: String?
        package let args: [String]
        package var lines: [Line]
    }

    package var processes: [Process]

    package init(contentsOf url: URL) throws {
        var processes: [Int: Process] = [:]
        let data = try Data(contentsOf: url)
        for raw in data.split(separator: 0x0A) where !raw.isEmpty {
            let json = try JSONValue.parse(Data(raw))
            let p = json["dir"] == nil ? json["proc"]?.int ?? 0 : json["p"]?.int ?? 0
            guard let dir = json["dir"]?.string else {
                processes[p] = Process(
                    index: p, cli: json["cli"]?.string, args: json["args"]?.array?.compactMap(\.string) ?? [],
                    lines: processes[p]?.lines ?? [])
                continue
            }
            guard let direction = Direction(rawValue: dir) else { continue }
            let line = Line(
                t: json["t"]?.double ?? 0, dir: direction, text: json["line"]?.string ?? "",
                status: json["status"]?.int.map { Int32($0) })
            processes[p, default: Process(index: p, cli: nil, args: [], lines: [])].lines.append(line)
        }
        self.processes = processes.keys.sorted().compactMap { processes[$0] }
    }
}

/// The paths a cassette doesn't keep: the session's working folder (in every form a CLI prints
/// it) becomes "/WORK", Claude's project-dir name for it "-WORK", Codex's home "/CODEX_HOME" and
/// the home folder "/HOME". `restore` puts this run's paths back.
package struct CassettePaths: Sendable {
    private let pairs: [(real: String, placeholder: String)]

    /// `codexHome`: the `CODEX_HOME` the CLI ran with (`~/.codex` when it had none).
    package init(work: URL, codexHome: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let codex = codexHome ?? home.appendingPathComponent(".codex")
        var pairs = Self.variants(work.path).map { ($0, "/WORK") } + Self.variants(work.path).map { (Self.encoded($0), "-WORK") }
        pairs += Self.variants(codex.path).map { ($0, "/CODEX_HOME") }
        pairs.append((home.path, "/HOME"))
        // Longest first, so a folder under home is "/WORK", not "/HOME/…".
        self.pairs = pairs.sorted { $0.0.count > $1.0.count }
    }

    /// The path as given, its real path, and both with and without /private: /tmp and /var are
    /// /private/tmp and /private/var, and a CLI may print either.
    private static func variants(_ path: String) -> Set<String> {
        var variants: Set<String> = [path]
        if let real = realpath(path, nil) {
            variants.insert(String(cString: real))
            free(real)
        }
        for path in variants {
            if path.hasPrefix("/private/") { variants.insert(String(path.dropFirst("/private".count))) }
            else if path.hasPrefix("/tmp/") || path.hasPrefix("/var/") { variants.insert("/private" + path) }
        }
        return variants
    }

    package func scrub(_ text: String) -> String {
        var text = text
        for (real, placeholder) in pairs where text.contains(real) {
            text = text.replacingOccurrences(of: real, with: placeholder)
        }
        return Self.scrubAccount(text)
    }

    /// The placeholders as this run's paths (the folder's real path, as the CLIs print it).
    package func restore(_ text: String) -> String {
        guard text.contains("WORK") || text.contains("/HOME") || text.contains("/CODEX_HOME") else { return text }
        let work = real("/WORK")
        return text.replacingOccurrences(of: "-WORK", with: Self.encoded(work))
            .replacingOccurrences(of: "/CODEX_HOME", with: real("/CODEX_HOME"))
            .replacingOccurrences(of: "/WORK", with: work)
            .replacingOccurrences(of: "/HOME", with: real("/HOME"))
    }

    /// The placeholder's path in its real form (the CLIs print real paths).
    private func real(_ placeholder: String) -> String {
        pairs.first { $0.placeholder == placeholder && $0.real.hasPrefix("/private/") }?.real
            ?? pairs.first { $0.placeholder == placeholder }?.real ?? placeholder
    }

    /// Claude's project-dir name for a folder: every character but ASCII letters and digits as "-".
    static func encoded(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    // Claude's `initialize` reply names the account; Codex's account events the plan and credits.
    private static let account = try! NSRegularExpression(
        pattern: #""(email|organization|subscriptionType|planType|balance)"(\s*:\s*)"(?:[^"\\]|\\.)*""#)

    private static func scrubAccount(_ text: String) -> String {
        guard text.contains("\"email\"") || text.contains("\"organization\"") || text.contains("\"subscriptionType\"")
            || text.contains("\"planType\"") || text.contains("\"balance\"")
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return account.stringByReplacingMatches(in: text, range: range, withTemplate: "\"$1\"$2\"SCRUBBED\"")
    }
}

/// Writes a cassette while a session runs: `StdioProcess` reports every CLI it starts through
/// `begin`, then each line through the returned track.
package final class CassetteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let paths: CassettePaths
    private let model: String?
    private var next = 0

    package init(url: URL, work: URL, codexHome: URL? = nil, model: String? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        paths = CassettePaths(work: work, codexHome: codexHome)
        self.model = model
    }

    deinit { try? handle.close() }

    func begin(executable: URL, arguments: [String], cwd: URL?) -> CassetteTrack {
        let index = lock.withLock {
            defer { next += 1 }
            return next
        }
        var header: [String: JSONValue] = [
            "cassette": 1, "proc": .number(Double(index)), "cli": .string(executable.lastPathComponent),
            "args": .array(arguments.map { .string(paths.scrub($0)) }), "cwd": .string(paths.scrub(cwd?.path ?? "")),
            "recorded": .string(Self.day.string(from: Date())),
        ]
        if let model { header["model"] = .string(model) }
        write(JSONValue.object(header).compact)
        return CassetteTrack(index: index, recorder: self)
    }

    fileprivate func record(_ index: Int, _ start: Date, _ dir: Cassette.Direction, line: String?, status: Int32? = nil) {
        var text = String(format: "{\"t\":%.3f,\"dir\":\"%@\",\"p\":%d", Date().timeIntervalSince(start), dir.rawValue, index)
        if let line { text += ",\"line\":" + Self.quoted(paths.scrub(line)) }
        if let status { text += ",\"status\":\(status)" }
        write(text + "}")
    }

    private func write(_ line: String) {
        lock.withLock { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// One CLI process's part of a cassette.
package final class CassetteTrack: Sendable {
    private let index: Int
    private let start = Date()
    private let recorder: CassetteRecorder

    fileprivate init(index: Int, recorder: CassetteRecorder) {
        self.index = index
        self.recorder = recorder
    }

    func record(_ dir: Cassette.Direction, _ line: String) {
        recorder.record(index, start, dir, line: line)
    }

    func exited(_ status: Int32) {
        recorder.record(index, start, .exit, line: nil, status: status)
    }
}
