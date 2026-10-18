import Foundation

/// Where an import's history comes from: a history file from anywhere (picked or dropped), or
/// a chat of a CLI in this folder (its own file is read).
public enum HandoffSource: Sendable, Hashable {
    case file(URL)
    case session(provider: String, id: String)
}

/// What an import would carry, for the picker to show before anything is written.
public struct HandoffPreview: Sendable, Equatable {
    public let file: URL
    /// The source format and its agent ("claude", "Claude Code").
    public let format: String
    public let product: String
    public let sessionId: String
    public let title: String
    /// The source's turns, and what's carried of them at each level.
    public let turns: Int
    public let full: Int
    public let condensed: Int
    public let bare: Int
    public let notCarried: Int
    /// The source's own summary of what came before its turns is carried.
    public let summary: Bool
    /// About this many tokens of the target's window, of a budget of `budget`.
    public let tokens: Int
    public let budget: Int
    /// The times the source's turns span, and those of the turns not carried.
    public let from: Date?
    public let to: Date?
    public let notCarriedFrom: Date?
    public let notCarriedTo: Date?
    /// The model, mode and effort it last ran on, in the source's own names.
    public let model: String?
    public let mode: String?
    public let effort: String?

    public var carried: Int { full + condensed + bare }

    package init(_ segment: HandoffSegment, _ plan: HandoffPlan, file: URL) {
        self.file = file
        format = segment.source
        product = segment.product
        sessionId = segment.sessionId
        title = segment.shownTitle
        turns = segment.turns.count
        full = plan.count(.full)
        condensed = plan.count(.condensed)
        bare = plan.count(.bare)
        notCarried = plan.notCarried
        summary = plan.summary != nil
        tokens = plan.tokens
        budget = plan.budget
        from = segment.turns.first?.at
        to = segment.turns.last?.at
        notCarriedFrom = plan.notCarriedFrom
        notCarriedTo = plan.notCarriedTo
        model = segment.model
        mode = segment.mode
        effort = segment.effort
    }
}

/// An import's steps, the same for any source format and target CLI: read the file into the
/// neutral form, fit it to the target's window, write it as the target's new session, and keep
/// the record. Blocking reads: call it off the main thread.
public enum HandoffImport {
    /// The file's history and what of it fits `writer`'s window on `model`; nil, quietly, when
    /// the file isn't importable.
    public static func plan(_ file: URL, for writer: any HandoffWriter, model: String?, window: Int? = nil)
        -> (segment: HandoffSegment, plan: HandoffPlan)?
    {
        guard let segment = HandoffFormats.read(file) else { return nil }
        let plan = HandoffBudget.plan(segment, window: window ?? writer.window(model: model))
        return plan.isEmpty ? nil : (segment, plan)
    }

    public static func preview(_ file: URL, for writer: any HandoffWriter, model: String?, window: Int? = nil) -> HandoffPreview? {
        try? inspect(file, for: writer, model: model, window: window).get()
    }

    /// `preview`, with why a file isn't importable (for the picker's tooltip).
    public static func inspect(_ file: URL, for writer: any HandoffWriter, model: String?, window: Int? = nil)
        -> Result<HandoffPreview, HandoffReadError>
    {
        HandoffFormats.check(file).map { segment in
            HandoffPreview(segment, HandoffBudget.plan(segment, window: window ?? writer.window(model: model)), file: file)
        }
    }

    /// Writes the planned history as the target's new session and keeps the record. Returns
    /// the record (its `target.session` is what the new chat resumes).
    public static func write(
        _ segment: HandoffSegment, _ plan: HandoffPlan, file: URL, into target: HandoffTarget, writer: any HandoffWriter
    ) async throws -> HandoffRecord {
        let written = try await writer.write(plan, into: target)
        let record = HandoffRecord(
            source: .init(cli: segment.source, session: segment.sessionId), sourceFile: file, sourceProduct: segment.product,
            cutoff: plan.cutoff, sourceTitle: segment.shownTitle, sourceModel: segment.model,
            target: .init(cli: writer.id, session: written.session), targetModel: target.model, folder: target.folder,
            carried: .init(plan), written: written.rows, instructions: target.instructions?.path)
        try await Task.detached { try HandoffRecords.save(record, history: plan.entries.map(\.turn)) }.value
        return record
    }
}
