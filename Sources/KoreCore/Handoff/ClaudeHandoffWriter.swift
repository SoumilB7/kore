import Foundation

/// The carried history into a new Claude Code session: Claude has no import, so Kore writes a
/// transcript of its own in Claude's store, which `claude --resume <id>` then opens (chained
/// onto its last row). It is always a new file, created exclusively: an existing transcript is
/// never opened for writing.
///
/// Rows: a meta user row with the note (the model reads it; it isn't shown as a prompt), then
/// per turn the user's prompt and one `<synthetic>` assistant row with the steps as labelled
/// text and the reply, so turns alternate with no tool pairs to balance. Then the title, mode
/// and last-prompt rows the CLI writes itself.
public struct ClaudeHandoffWriter: HandoffWriter {
    public let id = "claude"
    public let product = "Claude Code"
    public let company = "Anthropic"
    /// Measured: a first turn over ~300 carried tokens read 23,532 (2026-10-24).
    public let overhead = 23_000
    public let instructionFiles = ["CLAUDE.md", ".claude/CLAUDE.md"]

    public init() {}

    public func window(model: String?) -> Int { HandoffBudget.claudeWindow(model: model) }

    /// The transcript records the installed CLI's version, as the CLI's own rows do. Another
    /// agent's instructions aren't written here: the chat passes them at each launch.
    public func write(_ plan: HandoffPlan, into target: HandoffTarget) async throws -> HandoffWritten {
        let version = try await ClaudeAuth.version()
        let folder = target.folder
        let written = try await Task.detached {
            try Self.writeFile(plan, folder: folder, version: version, title: target.title, plan: target.planMode)
        }.value
        return HandoffWritten(session: written.session, rows: written.rows)
    }

    /// The CLI's own timestamps ("2026-10-20T08:43:46.741Z"). Thread-safe once configured.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The transcript's lines, and the uuids of its conversation rows.
    public static func lines(
        _ plan: HandoffPlan, sessionId: String, cwd: String, version: String, title: String, plan planMode: Bool,
        now: Date = Date()
    ) -> (lines: [JSONValue], rows: [String]) {
        var lines: [JSONValue] = []
        var rows: [String] = []
        var parent: String?
        var lastPrompt = ""
        var clock = now
        func row(_ type: String, _ message: JSONValue, extra: [String: JSONValue] = [:]) {
            let uuid = UUID().uuidString.lowercased()
            var fields: [String: JSONValue] = [
                "parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": false, "type": .string(type),
                "message": message, "uuid": .string(uuid), "timestamp": .string(iso.string(from: clock)),
                "cwd": .string(cwd), "sessionId": .string(sessionId), "version": .string(version), "gitBranch": "",
                "userType": "external", "entrypoint": "sdk-cli",
            ]
            fields.merge(extra) { _, new in new }
            lines.append(.object(fields))
            rows.append(uuid)
            parent = uuid
            clock = clock.addingTimeInterval(0.001)
        }
        var note = HandoffRender.note(plan, folder: URL(fileURLWithPath: cwd))
        if let summary = plan.summary { note += "\n\n" + HandoffRender.summary(summary, from: plan.product) }
        row("user", ["role": "user", "content": .string(note)], extra: ["isMeta": true])
        let mode: JSONValue = planMode ? "plan" : "default"
        for (index, entry) in plan.entries.enumerated() {
            let turn = HandoffRender.turn(entry.turn, entry.level)
            row("user", ["role": "user", "content": userContent(turn)], extra: ["permissionMode": mode])
            lastPrompt = turn.user
            let blocks: [JSONValue] = turn.assistant.map { ["type": "text", "text": .string($0)] }
            row(
                "assistant",
                [
                    "model": "<synthetic>", "id": .string("msg_kore_\(index + 1)"), "type": "message", "role": "assistant",
                    "content": .array(blocks), "stop_reason": "end_turn", "stop_sequence": .null,
                    "usage": ["input_tokens": 0, "output_tokens": 0],
                ])
        }
        lines.append(["type": "custom-title", "customTitle": .string(title), "sessionId": .string(sessionId)])
        lines.append(["type": "mode", "mode": planMode ? "plan" : "normal", "sessionId": .string(sessionId)])
        if let leaf = parent {
            lines.append(["type": "last-prompt", "lastPrompt": .string(String(lastPrompt.prefix(200))), "leafUuid": .string(leaf), "sessionId": .string(sessionId)])
        }
        return (lines, rows)
    }

    /// Writes the transcript as `<Claude's store>/projects/<folder key>/<new session id>.jsonl`.
    public static func writeFile(
        _ plan: HandoffPlan, folder: URL, version: String, title: String, plan planMode: Bool
    ) throws -> (session: String, file: URL, rows: [String]) {
        let sessionId = UUID().uuidString.lowercased()
        let (lines, rows) = Self.lines(plan, sessionId: sessionId, cwd: realPath(folder.path), version: version, title: title, plan: planMode)
        var data = Data()
        for line in lines {
            data.append(try line.encoded())
            data.append(0x0A)
        }
        let directory = ClaudeHistory.projectDirectory(for: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(sessionId).jsonl")
        try create(file, data)
        return (sessionId, file, rows)
    }

    /// A new file with `data`, failing if anything is already there (`O_EXCL`).
    static func create(_ file: URL, _ data: Data) throws {
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw HandoffError.cantWrite(file.path, String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw HandoffError.cantWrite(file.path, String(cString: strerror(errno))) }
    }

    /// A string, or text and image blocks.
    static func userContent(_ turn: HandoffRender.Turn) -> JSONValue {
        // Scaled as Claude takes them (≤2000 px, 5 MB in base64), the latest `maxImages` of them.
        let images = turn.images.suffix(ImageFit.maxImages).compactMap(ImageFit.fit)
        guard !turn.images.isEmpty || !turn.pdfs.isEmpty else { return .string(turn.user) }
        var blocks: [JSONValue] = [["type": "text", "text": .string(turn.user)]]
        blocks += images.map { ["type": "image", "source": ["type": "base64", "media_type": .string($0.mediaType), "data": .string($0.data)]] }
        if images.count < turn.images.count { blocks.append(["type": "text", "text": "[an image too large to carry]"]) }
        blocks += turn.pdfs.map { ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": .string($0.data)]] }
        return .array(blocks)
    }
}

public enum HandoffError: LocalizedError {
    case cantWrite(String, String)

    public var errorDescription: String? {
        switch self {
        case .cantWrite(let path, let reason): "couldn't write \(path): \(reason)"
        }
    }
}
