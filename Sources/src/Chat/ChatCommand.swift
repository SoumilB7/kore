import Foundation
import KoreCore

/// One call of a `ChatBackend`, as a value: what a chat on another machine (a box) asks of its
/// real backend there (link 1.5, `chat.call`). One case per call that crosses; the calls that stay
/// on this side (`start`, `close`, the account change's) have none.
///
/// On the wire it's the synthesized coding: `{"<case>": {<labels>}}`, unlabeled values as `_0`.
/// The case names and labels are the wire's keys: rename one and older peers stop reading it.
/// A tag a peer doesn't know reads as `.unknown(tag)` (`ChatCommand.decode`), which is refused.
package enum ChatCommand: Sendable, Codable {
    /// `files`: uploaded already, by the blob ids the box gave them.
    case send(text: String, files: [RelayFile], queued: String?, id: String?)
    case interrupt
    case respond(approval: String, decision: Decision)
    case setMode(String)
    case setPlanMode(Bool)
    case setModel(String)
    case setEffort(String)
    case setFastMode(Bool)
    case rename(String)
    case stopAgent(String)
    case stopCommand(String)
    case backgroundCommand(String)
    case commandOutput(String)
    case watchCommands(Bool)
    case agentHistory(String)
    case fork(message: String?, text: String)
    case forkAtEnd
    case rollback(message: String?, text: String)
    /// `turns` nil: the next page (`earlier()`); else `earlier(turns:)`.
    case earlier(turns: Int?)
    case earlierMessages
    case unloadPoint(message: String?, text: String)
    case unloaded(to: String)
    case compact(instructions: String)
    case usage
    case useReset(credit: String?, attempt: UUID)
    case setRemoteControl(Bool)
    case relaunch(reason: String)
    case listModels
    /// A tag this side doesn't know.
    case unknown(String)

    /// Its tag on the wire, also what logs and refusals name it by.
    package var name: String {
        switch self {
        case .send: "send"
        case .interrupt: "interrupt"
        case .respond: "respond"
        case .setMode: "setMode"
        case .setPlanMode: "setPlanMode"
        case .setModel: "setModel"
        case .setEffort: "setEffort"
        case .setFastMode: "setFastMode"
        case .rename: "rename"
        case .stopAgent: "stopAgent"
        case .stopCommand: "stopCommand"
        case .backgroundCommand: "backgroundCommand"
        case .commandOutput: "commandOutput"
        case .watchCommands: "watchCommands"
        case .agentHistory: "agentHistory"
        case .fork: "fork"
        case .forkAtEnd: "forkAtEnd"
        case .rollback: "rollback"
        case .earlier: "earlier"
        case .earlierMessages: "earlierMessages"
        case .unloadPoint: "unloadPoint"
        case .unloaded: "unloaded"
        case .compact: "compact"
        case .usage: "usage"
        case .useReset: "useReset"
        case .setRemoteControl: "setRemoteControl"
        case .relaunch: "relaunch"
        case .listModels: "listModels"
        case .unknown(let tag): tag
        }
    }

    /// Every call's tag (what a box lists as its capabilities, less what its policy refuses).
    package static let tags = [
        "send", "interrupt", "respond", "setMode", "setPlanMode", "setModel", "setEffort", "setFastMode", "rename", "stopAgent", "stopCommand",
        "backgroundCommand", "commandOutput", "watchCommands", "agentHistory", "fork", "forkAtEnd", "rollback", "earlier", "earlierMessages",
        "unloadPoint", "unloaded", "compact", "usage", "useReset", "setRemoteControl", "relaunch", "listModels",
    ]

    /// Reads a command; one whose tag (or shape) this side doesn't know is `.unknown`, never a
    /// failure.
    package static func decode(_ decoder: any Decoder) -> ChatCommand {
        if let command = try? ChatCommand(from: decoder) { return command }
        let tag = (try? decoder.container(keyedBy: AnyKey.self))?.allKeys.first?.stringValue
        return .unknown(tag ?? "")
    }
}

/// A file a relayed message carries: uploaded to the box first, named there by its blob id.
package struct RelayFile: Sendable, Codable, Equatable {
    package var blob: String
    package var name: String
    package var kind: AttachmentKind

    package init(blob: String, name: String, kind: AttachmentKind) {
        self.blob = blob
        self.name = name
        self.kind = kind
    }
}

/// What a relayed call gives back: the one field its call returns.
package struct RelayValue: Sendable, Codable {
    package var bool: Bool?
    package var text: String?
    package var events: [ChatEvent]?
    package var more: Bool?
    /// `fork`'s: the session and message the fork starts from; nil fields for `.fresh`.
    package var forkFrom: String?
    package var forkAt: String?
    package var messages: [EarlierMessage]?
    package var unloadEarlier: String?
    package var models: [ModelOption]?
    package var reading: PlanReading?
    package var outcome: PlanResetOutcome?

    package init() {}
}

/// Any key, for reading a tag that isn't known.
package struct AnyKey: CodingKey {
    package var stringValue: String
    package var intValue: Int?
    package init(stringValue: String) { self.stringValue = stringValue }
    package init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
