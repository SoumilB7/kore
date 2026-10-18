import Foundation

@testable import KoreUI

/// A `ChatEvent` as a short tag ("turnStarted", "tool Bash", "queued inTurn"), so a test can
/// say which events came, in what order, without their ids, times or text.
func tag(_ event: ChatEvent) -> String {
    switch event {
    case .sessionIdentified: "session"
    case .titleChanged: "title"
    case .controlsLoaded: "controls"
    case .modeChanged(let change): "mode \(change.mode)"
    case .planModeChanged(let change): "plan \(change.on)"
    case .turnStarted(_, let origin, _): "turnStarted \(origin)"
    case .turnOrigin(_, let origin): "turnOrigin \(origin)"
    case .turnFinished(_, let outcome, _): "turnFinished \(outcome)"
    case .turnChanges: "turnChanges"
    case .queuedMessage(_, let delivery):
        switch delivery {
        case .inTurn: "queued inTurn"
        case .nextTurn: "queued nextTurn"
        case .dropped: "queued dropped"
        }
    case .messageQueued: "messageQueued"
    case .userMessage: "user"
    case .peerMessage: "peer"
    case .text(_, let kind, _, _): "text \(kind)"
    case .finalAnswer: "final"
    case .toolStarted(let call, _): "tool \(call.name)"
    case .toolOutput: "toolOutput"
    case .toolFinished(_, _, let isError, _): isError ? "toolFailed" : "toolFinished"
    case .toolStopped: "toolStopped"
    case .fileChanged: "fileChanged"
    case .notice: "notice"
    case .agentSpawned: "agentSpawned"
    case .agentProgress: "agentProgress"
    case .agentFinished: "agentFinished"
    case .agentResumed: "agentResumed"
    case .approvalRequested: "approval"
    case .approvalWithdrawn: "approvalWithdrawn"
    case .planReady: "planReady"
    case .exited: "exited"
    case .compacted: "compacted"
    case .compactionStarted(let auto): "compactionStarted \(auto)"
    case .compactionSummary: "summary"
    case .compactionFailed: "compactionFailed"
    case .contextUsage: "context"
    case .earlierHistory: "earlier"
    case .replayed: "replayed"
    }
}

/// Tags with runs of the same one (streamed text, tool output) kept once.
func tags(_ events: [ChatEvent]) -> [String] {
    events.map(tag).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
}

/// The tags without context reports, which come after most model calls and say nothing about
/// the turn's shape.
func shape(_ events: [ChatEvent]) -> [String] {
    tags(events.filter { if case .contextUsage = $0 { false } else { true } })
}
