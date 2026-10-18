import Foundation
import KoreCore

/// The other half of an imported chat: what was carried from the source, shown above the
/// divider, from the neutral turns kept with the import's record (the source file may be gone
/// by the next time the chat opens). The target CLI's own copy of it (Kore's rows in a Claude
/// transcript) is hidden, so nothing shows twice; Codex shows injected history as no turns.
@MainActor
final class ImportedHistory {
    let record: HandoffRecord
    private var turns: [HandoffTurn]?

    init(record: HandoffRecord, turns: [HandoffTurn]? = nil) {
        self.record = record
        self.turns = turns
    }

    /// The import that made this session, when Kore made it by one.
    static func of(session id: String) -> ImportedHistory? {
        HandoffRecords.record(target: id).map { ImportedHistory(record: $0) }
    }

    /// The carried turns as events, read off the main thread the first time.
    func events() async -> [ChatEvent] {
        if turns == nil {
            let session = record.target.session
            turns = await Task.detached { HandoffRecords.history(target: session) }.value ?? []
        }
        let turns = turns ?? []
        return await Task.detached { ImportedEvents.events(turns) }.value
    }

    /// How full the chat's context is about to be, until its CLI says: what was carried plus the
    /// CLI's own prompt and tools, against the window the import was fitted to.
    var estimate: ContextUsage {
        let overhead = HandoffWriters.writer(record.target.cli)?.overhead ?? 0
        let window = Int((Double(record.carried.budget) / HandoffBudget.share).rounded())
        var usage = ContextUsage(used: record.carried.tokens + overhead, window: window, autoCompacts: nil, at: record.at)
        usage.approximate = true
        return usage
    }

    /// "Continued in Codex · gpt-6-luna · 24 Oct", under the imported part.
    func divider(product: String) -> String {
        (["Continued in \(product)", record.targetModel, Self.day.string(from: record.at)].compactMap { $0 }).joined(separator: " · ")
    }

    /// "Carried to Codex from here" over the oldest carried turn, with what was left out:
    /// only when turns weren't carried and no summary of the source's covers them.
    func cutMark(product: String) -> (text: String, help: String)? {
        let carried = record.carried
        guard carried.notCarried > 0, !carried.summary else { return nil }
        var parts = [
            carried.notCarriedKnown == false
                ? "Earlier turns not carried"
                : "\(carried.notCarried) earlier \(carried.notCarried == 1 ? "turn" : "turns") not carried"
                    + ImportState.span(carried.notCarriedFrom, carried.notCarriedTo)
        ]
        if carried.condensed > 0 { parts.append("\(carried.condensed) condensed") }
        if carried.bare > 0 { parts.append("\(carried.bare) as prompt and reply") }
        return ("Carried to \(product) from here", parts.joined(separator: " · "))
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
}

/// Neutral turns as Kore's events, the same whichever agent they came from: the prompt, each
/// step as a tool row, the reply.
enum ImportedEvents {
    static func events(_ turns: [HandoffTurn]) -> [ChatEvent] {
        var events: [ChatEvent] = []
        for (index, turn) in turns.enumerated() {
            let id = "import-\(index)"
            events.append(.turnStarted(id, origin: .user, at: turn.at ?? .distantPast))
            let prompt = ([turn.prompt] + turn.files + turn.images.map { _ in "[image]" }).filter { !$0.isEmpty }
            events.append(.userMessage(text: prompt.joined(separator: "\n"), attachments: []))
            for (number, step) in turn.steps.enumerated() {
                let call = "\(id)-\(number)"
                // Its words between calls, as Kore shows any turn's: they fold under the last ones.
                if step.kind == .text {
                    events.append(.text(call, .answer, step.output))
                    continue
                }
                events.append(
                    .toolStarted(
                        ToolCall(
                            id: call, name: step.tool, detail: HandoffRender.oneLine(step.title), input: step.detail,
                            readOnly: step.kind == .read || step.kind == .search)))
                switch step.status {
                case .interrupted: events.append(.toolStopped(id: call))
                case .ok, .error:
                    events.append(.toolFinished(id: call, output: step.output.isEmpty ? nil : step.output, isError: step.status == .error))
                }
            }
            if !turn.reply.isEmpty {
                events.append(.finalAnswer("\(id)-reply"))
                events.append(.text("\(id)-reply", .answer, turn.reply))
            }
            let outcome: TurnOutcome =
                switch turn.end {
                case .done: .completed
                case .interrupted: .interrupted
                case .failed(let reason): .failed(reason)
                }
            events.append(.turnFinished(id, outcome, duration: nil))
        }
        return events
    }
}
