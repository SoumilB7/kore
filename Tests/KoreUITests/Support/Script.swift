import Foundation

@testable import KoreUI

/// A transcript fed by hand: short calls for the events a rule test needs, and the drawn rows
/// as one line each ("§ hello", "tool Bash stopped", "fold Worked for 2s interrupted").
@MainActor
final class Script {
    let store = TranscriptStore()

    init(_ provider: ProviderDescriptor = .claude) { store.provider = provider }

    func on(_ events: ChatEvent...) { events.forEach(store.apply) }
    func send(_ text: String, id: String? = nil) { on(.userMessage(text: text, attachments: [], id: id)) }
    func start(_ turn: TurnID) { on(.turnStarted(turn, origin: .user, at: Date())) }
    func tool(_ id: String, _ name: String = "Bash") { on(.toolStarted(ToolCall(id: id, name: name, detail: id))) }
    func done(_ id: String, _ output: String = "ok") { on(.toolFinished(id: id, output: output, isError: false)) }
    func say(_ block: BlockID, _ text: String) { on(.text(block, .answer, text)) }
    func finish(_ turn: TurnID, _ outcome: TurnOutcome = .completed) { on(.turnFinished(turn, outcome, duration: .seconds(2))) }

    /// A whole turn: a message, one tool call, an answer.
    func turn(_ turn: TurnID, _ message: String) {
        send(message)
        start(turn)
        tool("\(turn)-tool")
        done("\(turn)-tool")
        say("\(turn)-answer", "answer \(turn)")
        on(.finalAnswer("\(turn)-answer"))
        finish(turn)
    }

    var sections: [TranscriptStore.SectionModel] {
        store.drawNow()
        return store.sections
    }

    var items: [TranscriptStore.Item] { sections.flatMap(\.items) }

    /// Each section as its header line ("§ text", "§ start" before the first message) and then
    /// its items, one line each.
    var lines: [String] {
        sections.flatMap { section in
            ["§ " + (section.header.map(\.text) ?? "start")] + section.items.map { Self.line($0.row) }
        }
    }

    static func line(_ row: TranscriptStore.Row) -> String {
        switch row {
        case .entry(let e): "\(e.kind) \(e.text)"
        case .tool(let e, _): "tool \(e.toolName ?? "") " + (e.stopped ? "stopped" : e.done ? (e.isError ? "failed" : "done") : "running")
        case .thinking: "thinking"
        case .file(let e, _, _): "file \(e.toolName ?? "")"
        case .agent(let e, _, _): "agent \(e.agent?.name ?? "")"
        case .fold(let f): "fold" + (f.live ? " live" : "") + (f.outcome.map { " \($0)" } ?? "") + (f.now.map { " now \($0.label)" } ?? "")
        case .rule: "rule"
        case .outcome(_, let text): "outcome \(text)"
        case .changes: "changes"
        case .explored(let entries, _): "explored \(entries.count)"
        case .message(let e, _, _): "message \(e.text)"
        case .summary(let e, _): "summary \(e.text)"
        case .queued(let e): "queued \(e.text)"
        case .spinner: "spinner"
        }
    }
}
