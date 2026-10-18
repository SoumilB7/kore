import Foundation
import KoreCore

/// Kore's stdin lines, handed from the reader thread to the player.
final class LineQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []
    private var closed = false

    func push(_ line: String) {
        condition.withLock {
            lines.append(line)
            condition.signal()
        }
    }

    func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }

    /// The next line, waiting for it; nil once stdin is closed and every line was taken.
    func pop() -> String? {
        condition.withLock {
            while lines.isEmpty && !closed { condition.wait() }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }
}

/// Which recorded processes the run's live processes play, in a file every one of them shares
/// (each CLI Kore starts is its own `kore-fake-cli`). Without a file, this process is alone.
struct Claims {
    let path: String?

    /// Takes the first of `indices` no other process has.
    func take(from indices: [Int]) -> Int? {
        update { taken in
            guard let index = indices.first(where: { !taken.contains($0) }) else { return nil }
            taken.insert(index)
            return index
        }
    }

    /// Gives `from` back and takes `to`, if no other process has it.
    func move(from: Int, to: Int) -> Bool {
        update { taken in
            guard !taken.contains(to) else { return false }
            taken.remove(from)
            taken.insert(to)
            return true
        }
    }

    private func update<T>(_ change: (inout Set<Int>) -> T) -> T {
        guard let path else {
            var alone: Set<Int> = []
            return change(&alone)
        }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            var alone: Set<Int> = []
            return change(&alone)
        }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var taken = Set(text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
        let result = change(&taken)
        let out = taken.sorted().map(String.init).joined(separator: "\n")
        ftruncate(fd, 0)
        _ = out.withCString { pwrite(fd, $0, strlen($0), 0) }
        return result
    }
}

/// When a line Kore sent is the one a recording expects. Kore's lines carry ids and timestamps
/// of their own, so the comparison is by what the line asks for: its type or method, its
/// subtype, and its text.
enum FakeMatch {
    static func matches(recorded: String, live: String) -> Bool {
        guard let a = try? JSONValue.parse(Data(recorded.utf8)), let b = try? JSONValue.parse(Data(live.utf8)) else {
            return normalized(recorded) == normalized(live)
        }
        return signature(a) == signature(b)
    }

    static func signature(_ json: JSONValue) -> String {
        if let method = json["method"]?.string {
            let params = json["params"]
            // A prompt or a steer: its text. Settings a turn sends every time don't tell turns apart.
            let text = params?["input"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
            return "method \(method) \(normalized(text)) \(params?["threadId"]?.string ?? "")"
        }
        if json["id"] != nil, json["result"] != nil || json["error"] != nil {
            // Kore answering the CLI's own request (an approval): the id came from the recording.
            return "reply \(json["id"]?.compact ?? "") \(json["error"] == nil ? "ok" : "error")"
        }
        switch json["type"]?.string {
        case "control_request":
            let request = json["request"]
            var parts = ["control_request", request?["subtype"]?.string ?? ""]
            if let mode = request?["mode"]?.string { parts.append(mode) }
            if let cancel = request?["cancel_queued"]?.bool { parts.append("cancel_queued \(cancel)") }
            return parts.joined(separator: " ")
        case "control_response":
            let response = json["response"]
            let behavior = response?["response"]?["behavior"]?.string ?? ""
            return "control_response \(response?["subtype"]?.string ?? "") \(behavior)"
        case "user":
            return "user " + normalized(text(json["message"]?["content"]))
        case let type?:
            return "type \(type)"
        default:
            return normalized(json.compact)
        }
    }

    /// A Claude message's text: a string, or its text blocks.
    private static func text(_ content: JSONValue?) -> String {
        content?.string ?? content?.array?.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n") ?? ""
    }

    /// What a raw line asks for, as `matches` compares it.
    static func signature(of line: String) -> String {
        (try? JSONValue.parse(Data(line.utf8))).map(signature) ?? normalized(line)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func sameArguments(_ recorded: [String], _ live: [String]) -> Bool {
        recorded == live
    }
}

/// The ids Kore made up in the recording against the ones it makes up now, learned from the
/// lines it sends, put back into what the recording answers.
struct IdMap {
    /// Fields that hold ids Kore chooses: Claude's control `request_id`s and message `uuid`s,
    /// Codex's JSON-RPC `id`s and `clientUserMessageId`s, and where the CLIs echo them.
    static let keys: Set<String> = [
        "id", "request_id", "uuid", "clientUserMessageId", "clientId", "message_uuid", "command_uuid", "source_uuid",
        "user_message_uuids",
    ]

    private var strings: [String: String] = [:]
    private var numbers: [Double: Double] = [:]

    mutating func learn(recorded: String, live: String) {
        guard let a = try? JSONValue.parse(Data(recorded.utf8)), let b = try? JSONValue.parse(Data(live.utf8)) else { return }
        pair(a, b, key: nil)
    }

    private mutating func pair(_ a: JSONValue, _ b: JSONValue, key: String?) {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for (k, v) in x { if let w = y[k] { pair(v, w, key: k) } }
        case (.array(let x), .array(let y)):
            for (v, w) in zip(x, y) { pair(v, w, key: key) }
        case (.string(let x), .string(let y)) where key.map(Self.keys.contains) == true && x != y:
            strings[x] = y
        case (.number(let x), .number(let y)) where key == "id" && x != y:
            numbers[x] = y
        default:
            break
        }
    }

    /// `text` with the recording's ids as this run's. Lines without one go out unchanged.
    func rewrite(_ text: String) -> String {
        let hasString = !strings.isEmpty && strings.keys.contains { text.contains($0) }
        let hasNumber = !numbers.isEmpty && text.contains("\"id\"")
        guard hasString || hasNumber, let json = try? JSONValue.parse(Data(text.utf8)) else { return text }
        var changed = false
        let out = replace(json, key: nil, top: true, changed: &changed)
        return changed ? out.compact : text
    }

    private func replace(_ json: JSONValue, key: String?, top: Bool, changed: inout Bool) -> JSONValue {
        switch json {
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (k, v) in fields {
                // A JSON-RPC id is the top-level one; numbers elsewhere aren't Kore's.
                if top, k == "id", case .number(let n) = v, let live = numbers[n] {
                    result[k] = .number(live)
                    changed = true
                } else {
                    result[k] = replace(v, key: k, top: false, changed: &changed)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { replace($0, key: key, top: false, changed: &changed) })
        case .string(let s) where key.map(Self.keys.contains) == true:
            guard let live = strings[s] else { return json }
            changed = true
            return .string(live)
        default:
            return json
        }
    }
}
