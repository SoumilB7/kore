import Foundation

/// One agent's history file format: recognised from its first lines, read whole into the
/// neutral form. A new agent's history is one type conforming to this, plus a line in
/// `HandoffFormats.all`.
public protocol HandoffFormat: Sendable {
    /// Who writes it ("claude", "codex"): the id a provider of that CLI has.
    var id: String { get }
    /// What the agent is called in what the target is told ("Claude Code").
    var product: String { get }
    /// Where the agent keeps its histories, for a file picker to start in.
    var store: URL { get }
    /// What the file is, from its first lines only; nil when it isn't this format. Strict: the
    /// format's own structure, not merely JSON lines.
    func identify(_ head: HandoffHead) -> HandoffIdentity?
    /// The history, or a throw: a file damaged part-way imports nothing. `window`: the target's,
    /// when known; a format that can read from the end may stop once its turns fill that
    /// window's budget (`HandoffSegment.earlier` counts what it left unread).
    func read(_ file: URL, identity: HandoffIdentity, window: Int?) throws -> HandoffSegment
}

/// A file's first lines, parsed (nil: a line that isn't JSON). A last line cut off by the read
/// is left out.
public struct HandoffHead: Sendable {
    public let file: URL
    public let lines: [JSONValue?]

    /// Up to `maxLines` lines from the first `maxBytes` bytes.
    public init(file: URL, maxLines: Int = 200, maxBytes: Int = 4 << 20) {
        self.file = file
        var data = Data()
        var complete = false
        var breaks = 0
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            while data.count < maxBytes, breaks < maxLines {
                guard let more = try? handle.read(upToCount: 256 << 10), !more.isEmpty else {
                    complete = true
                    break
                }
                breaks += more.count { $0 == 0x0A }
                data += more
            }
        }
        var lines = data.jsonLines()
        if !complete, data.last != 0x0A { lines = lines.dropLast() }
        self.lines = lines.prefix(maxLines).map { try? JSONValue.parse($0) }
    }

    public init(file: URL, lines: [JSONValue?]) {
        self.file = file
        self.lines = lines
    }

    /// Every line is a JSON object.
    public var allObjects: Bool { !lines.isEmpty && lines.allSatisfy { $0?.object != nil } }
}

/// What a recognised history file is.
public struct HandoffIdentity: Sendable, Equatable {
    public let format: String
    public let product: String
    public let file: URL
    public let sessionId: String
    public let cwd: String?
    public let title: String?

    public init(format: String, product: String, file: URL, sessionId: String, cwd: String? = nil, title: String? = nil) {
        self.format = format
        self.product = product
        self.file = file
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
    }
}

/// The formats Kore can import, and the one place that goes through them.
public enum HandoffFormats {
    public static let all: [any HandoffFormat] = [ClaudeTranscriptFormat(), CodexRolloutFormat()]

    public static func format(_ id: String) -> (any HandoffFormat)? { all.first { $0.id == id } }

    /// The format of a file, from its first lines; nil for anything not recognised. `quick`:
    /// fewer lines, for a drag or an open panel asking about file after file (answers are kept
    /// per file and modification).
    public static func identify(_ file: URL, quick: Bool = false) -> HandoffIdentity? {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        let stamp = quick ? Self.stamp(file) : ""
        if quick, let known = lock.withLock({ sniffed[file.path] }), known.stamp == stamp { return known.identity }
        let head = quick ? HandoffHead(file: file, maxLines: 40, maxBytes: 512 << 10) : HandoffHead(file: file)
        let identity = all.lazy.compactMap { $0.identify(head) }.first
        if quick { lock.withLock { sniffed[file.path] = (stamp, identity) } }
        return identity
    }

    nonisolated(unsafe) private static var sniffed: [String: (stamp: String, identity: HandoffIdentity?)] = [:]

    /// A file's history in the neutral form; nil, quietly, for a file no format recognises, one
    /// damaged part-way, or one with nothing to carry. Blocking file IO: call it off the main
    /// thread. The last file read is kept (a preview, then the import, read it once).
    public static func read(_ file: URL, window: Int? = nil) -> HandoffSegment? {
        try? check(file, window: window).get()
    }

    /// `read`, with why a file isn't importable, in a line (for a tooltip, never an alert).
    public static func check(_ file: URL, window: Int? = nil) -> Result<HandoffSegment, HandoffReadError> {
        let stamp = Self.stamp(file) + "/\(window ?? 0)"
        if let cached = lock.withLock({ last }), cached.file == file, cached.stamp == stamp { return .success(cached.segment) }
        guard let identity = identify(file), let format = format(identity.format) else {
            return .failure(HandoffReadError("Not a chat format Kore knows"))
        }
        let segment: HandoffSegment
        do {
            segment = try format.read(file, identity: identity, window: window)
        } catch let error as HandoffReadError {
            return .failure(error)
        } catch {
            return .failure(HandoffReadError("Couldn't read the file"))
        }
        guard !segment.isEmpty else { return .failure(HandoffReadError("No turns in this file")) }
        lock.withLock { last = (file, stamp, segment) }
        return .success(segment)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (file: URL, stamp: String, segment: HandoffSegment)?

    private static func stamp(_ file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)/\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

/// A file a format couldn't read whole.
public struct HandoffReadError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// The CLIs' own text in a user message: tags the harness wraps its context, notices and command
/// echoes in. Only these are left out; a prompt the user began with "<" is theirs.
enum HandoffHarness {
    static let tags: Set<String> = [
        "system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat", "command-name",
        "command-message", "command-args", "task-notification", "user-prompt-submit-hook", "bash-input", "bash-stdout",
        "bash-stderr", "environment_context", "user_instructions", "permissions", "turn_aborted", "user_shell_command",
        "INSTRUCTIONS", "subagent_notification", "collaboration_mode", "ide_selection", "ide_opened_file",
        "new-diagnostics", "persisted-output", "skill", "personality_spec", "app-context", "model_switch",
    ]

    static func isHarness(_ text: String) -> Bool {
        let text = text.drop(while: \.isWhitespace)
        guard text.first == "<" else { return false }
        let name = text.dropFirst().prefix { !($0 == ">" || $0 == " " || $0 == "/") }
        return tags.contains(String(name))
    }

    /// "/name args" from a slash command's echo (`<command-name>/name</command-name>` …).
    static func command(_ text: String) -> String? {
        guard let name = value("command-name", in: text), !name.isEmpty else { return nil }
        let args = value("command-args", in: text) ?? ""
        let command = name.hasPrefix("/") ? name : "/" + name
        return args.isEmpty ? command : command + " " + args
    }

    private static func value(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
