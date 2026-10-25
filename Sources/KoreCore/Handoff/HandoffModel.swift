import Foundation

/// A chat's history carried into a new chat of another (or the same) agent CLI
/// (design/chat-handoff.md). Every direction goes through this neutral form, so each agent's
/// quirks stay at its edge: a source format (`HandoffFormat`) reads its history file into
/// `HandoffSegment`, `HandoffBudget` picks what fits the target's window, and a writer
/// (`HandoffWriter`) gives it to the target CLI in that CLI's own format. Nothing here knows
/// which agents there are; `HandoffFormats` and `HandoffWriters` list them.

/// One image, as base64 with its media type (Claude's blocks and Codex's data URLs both are).
public struct HandoffImage: Sendable, Hashable, Codable {
    public let mediaType: String
    public let data: String

    public init(mediaType: String, data: String) {
        self.mediaType = mediaType
        self.data = data
    }

    public var dataURL: String { "data:\(mediaType);base64,\(data)" }

    /// From a `data:` URL; nil for any other.
    public init?(dataURL: String) {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ","),
            dataURL[..<comma].hasSuffix(";base64")
        else { return nil }
        mediaType = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma].dropLast(7))
        data = String(dataURL[dataURL.index(after: comma)...])
    }
}

/// One tool call and its result, or (`text`) something the assistant said between them.
public struct HandoffStep: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case command, read, search, edit, write, delete, web, agent, plan, question, mcp, other
        /// The assistant's words before the turn's last ones, in `output`, in their place.
        case text
    }

    public enum Status: String, Sendable, Codable { case ok, error, interrupted }

    public var kind: Kind
    /// The source CLI's name for it ("Bash", "exec_command"), as the labelled text names it.
    public var tool: String
    /// One line: "git status", "Edit Sources/A.swift", "Agent: Find TODOs".
    public var title: String
    /// The command, unified diff, query or prompt, when readable.
    public var detail: String
    /// What came back.
    public var output: String
    public var images: [HandoffImage]
    public var status: Status
    /// A command's exit code, when the source says.
    public var exitCode: Int?
    /// Lines added and removed, for an edit's condensed line.
    public var added = 0
    public var removed = 0

    public init(
        kind: Kind, tool: String, title: String, detail: String = "", output: String = "", images: [HandoffImage] = [],
        status: Status = .ok
    ) {
        self.kind = kind
        self.tool = tool
        self.title = title
        self.detail = detail
        self.output = output
        self.images = images
        self.status = status
    }
}

/// One user prompt and all that came of it.
public struct HandoffTurn: Sendable, Hashable, Codable {
    public enum End: Sendable, Hashable, Codable {
        case done
        case interrupted
        case failed(String)
    }

    /// The source's id for the turn: the prompt entry's uuid (Claude), the turn id (Codex).
    public var id: String
    public var prompt: String
    public var images: [HandoffImage] = []
    /// Attachments that don't carry as content ("[document: spec.pdf]").
    public var files: [String] = []
    public var steps: [HandoffStep] = []
    /// The turn's last assistant text, when nothing came after it; the texts before it are
    /// `text` steps, in order among the tool calls.
    public var reply = ""
    public var end = End.done
    public var at: Date?
    /// The last source item of the turn (the cutoff, when it's the newest).
    public var lastItem: String
    /// How the target was given it, in the history Kore keeps of an import (nil before).
    public var carriedAs: HandoffPlan.Level?

    public init(id: String, prompt: String, at: Date? = nil) {
        self.id = id
        self.prompt = prompt
        self.at = at
        lastItem = id
    }

    /// The assistant's last words: the reply, else its last text (a turn that ended in a call).
    public var finalText: String {
        reply.isEmpty ? steps.last { $0.kind == .text }?.output ?? "" : reply
    }

    /// Something the assistant said, in its place among the steps.
    mutating func say(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        steps.append(HandoffStep(kind: .text, tool: "", title: "", output: text))
    }

    /// At the turn's end: its last words, when nothing came after them, are its reply.
    mutating func settleReply() {
        guard reply.isEmpty, let last = steps.last, last.kind == .text else { return }
        reply = last.output
        steps.removeLast()
    }
}

/// One agent's part of a chat, oldest turn first.
public struct HandoffSegment: Sendable, Codable {
    /// The format it was read from (`HandoffFormat.id`), and the agent's name for the target's note.
    public var source: String
    public var product: String
    public var sessionId: String
    /// The folder it ran in, and its title, when the file says.
    public var cwd: String?
    public var title: String?
    /// The model the source ran on last, for the target's note.
    public var model: String?
    /// The mode and effort it last ran in, as the source names them.
    public var mode: String?
    public var effort: String?
    /// The source's own compaction summary when it's readable (Claude's): everything before
    /// the first turn is inside it.
    public var summary: String?
    public var turns: [HandoffTurn]
    /// Items of types this reader doesn't know (a newer CLI's), counted for the note.
    public var unknown = 0
    /// Turns before `turns` that weren't read (a long file read from its end only as far as the
    /// budget needed); nil when there are some but they weren't counted.
    public var earlier: Int? = 0

    public init(
        source: String, product: String, sessionId: String, model: String? = nil, summary: String? = nil, turns: [HandoffTurn] = []
    ) {
        self.source = source
        self.product = product
        self.sessionId = sessionId
        self.model = model
        self.summary = summary
        self.turns = turns
    }

    public var firstItem: String? { turns.first?.id }
    public var lastItem: String? { turns.last?.lastItem }
    /// Nothing in it to carry.
    public var isEmpty: Bool { turns.isEmpty && summary == nil }
    /// Its title, else its first prompt's first line.
    public var shownTitle: String {
        if let title, !title.isEmpty { return title }
        let prompt = turns.first { !$0.prompt.isEmpty }?.prompt ?? ""
        return HandoffRender.oneLine(prompt).isEmpty ? product : HandoffRender.oneLine(prompt)
    }
}
