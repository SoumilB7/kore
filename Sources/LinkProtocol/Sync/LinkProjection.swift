import Foundation
import src

/// What the projector reads beyond the transcript's log: a message's files, and markdown as
/// the link's render tree when the host renders it (the Mac app, with its own parser). The
/// projector itself renders nothing: a host that doesn't (a box) gives nil, and the text goes
/// raw for the client to render.
@MainActor
package protocol LinkReading {
    func chips(_ entry: TranscriptLog.Entry) -> [Attachment]
    func blocks(_ markdown: String) -> [Block]?
}

/// The transcript as the link sends it: entries and turns from `src`'s log, their text capped,
/// paths made relative.
@MainActor
package enum LinkProjection {
    /// The most of a message, answer or notice's text sent at once; `entry.more` reads the rest.
    package static let textCap = 64 * 1024
    /// A tool call's input.
    package static let inputCap = 2 * 1024
    /// A tool's output: its start and its end.
    package static let resultHead = 1024
    package static let resultTail = 3 * 1024

    // MARK: Transcript

    package static func entry(_ e: TranscriptLog.Entry, folder: URL, reading: any LinkReading) -> LinkEntry {
        let chips = reading.chips(e)
        let kind: LinkEntry.Kind =
            switch e.kind {
            case .user: .user
            case .answer: .answer
            case .thinking: .thinking
            case .plan: .plan
            case .tool: .tool
            case .agent: .agent
            case .notice: .notice
            case .peer: .peer
            case .divider: .divider
            case .mode: .mode
            case .summary: .summary
            }
        let text = capped(e.text, textCap)
        let formatted = [.answer, .plan, .summary].contains(kind)
        var tool: LinkEntry.Tool?
        if e.kind == .tool, let name = e.toolName {
            let input = e.input.map { capped($0, inputCap) }
            let result = e.result.map(headAndTail)
            tool = LinkEntry.Tool(
                name: name, summary: e.summary, input: input?.text, inputLen: e.input?.unicodeScalars.count ?? 0,
                path: e.path.map { relative($0, to: folder) }, readOnly: e.readOnly, result: result,
                resultLen: e.result?.unicodeScalars.count ?? 0)
        }
        let doc = formatted && !e.text.isEmpty ? reading.blocks(text.text) : nil
        return LinkEntry(
            id: e.id.uuidString, kind: kind, turn: e.turn, text: doc != nil || e.text.isEmpty ? nil : text.text,
            doc: doc, textLen: text.length, done: e.done, isError: e.isError,
            stopped: e.stopped, inTurn: e.inTurn, tool: tool,
            changes: e.changes.isEmpty ? nil : e.changes.map { .init(path: relative($0.path, to: folder), added: $0.added, removed: $0.removed) },
            agent: e.agent.map { .init(id: $0.id, name: $0.name, status: $0.statusName) },
            attachments: chips.isEmpty ? nil : chips.enumerated().map { i, a in
                LinkAttachment(ref: attachmentRef(entryId: e.id.uuidString, index: i), name: a.name, kind: attachmentKind(a.kind))
            })
    }

    /// An attachment's ref: its message's id and its place there. It names nothing on disk.
    package static func attachmentRef(entryId: String, index: Int) -> String { "\(entryId)/\(index)" }

    package static func attachmentKind(_ kind: Attachment.Kind) -> LinkAttachment.Kind {
        switch kind {
        case .image: .image
        case .text: .text
        case .pdf: .pdf
        case .other: .other
        }
    }

    package static func turn(_ t: TranscriptLog.Turn) -> LinkTurn {
        let outcome: LinkTurn.Outcome =
            switch t.outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed: .failed
            case .authFailed: .authFailed
            case .slept: .slept
            }
        return LinkTurn(
            id: t.id, startedAt: (t.startedAt.timeIntervalSince1970 * 1000).rounded(), duration: t.duration, finished: t.finished,
            outcome: outcome)
    }

    // MARK: Text

    /// At most `cap` of the text, and its whole length (in Unicode scalars, as `entry.more` counts).
    package static func capped(_ text: String, _ cap: Int) -> (text: String, length: Int, cut: Bool) {
        let scalars = text.unicodeScalars
        let length = scalars.count
        guard length > cap else { return (text, length, false) }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: scalars.prefix(cap))
        return (String(head), length, true)
    }

    /// A piece of `text` from `offset`, at most `textCap` scalars: what `entry.chunk` and
    /// `card.chunk` carry.
    package static func piece(_ text: String, from offset: Int) -> (text: String, offset: Int, total: Int) {
        let scalars = Array(text.unicodeScalars)
        let start = min(max(offset, 0), scalars.count)
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[start..<min(start + textCap, scalars.count)])
        return (String(piece), start, scalars.count)
    }

    /// A tool's output, its start and end when it's long.
    package static func headAndTail(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > resultHead + resultTail else { return text }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: scalars.prefix(resultHead))
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars.suffix(resultTail))
        return String(head) + "\n…\n" + String(tail)
    }

    package static func relative(_ path: String, to folder: URL) -> String {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : homeRelative(path)
    }

    package static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
