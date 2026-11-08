import Foundation
import KoreCore

// The wire form of `ChatEvent`, `ChatCommand` and the enums inside them (link 1.5): a `type` tag
// per case and a named key per field, written out here, so renaming a Swift case or label never
// changes what crosses. A tag this side doesn't know reads as a failure the caller skips (an event)
// or as `.unknown` (a command); `Tests/Fixtures/stream/v1` holds the golden forms.

/// Reads and writes `{"type": …, <field>: …}`.
struct Tagged {
    var c: KeyedEncodingContainer<AnyKey>

    init(_ encoder: any Encoder, _ type: String) throws {
        c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(type, forKey: AnyKey(stringValue: "type"))
    }

    mutating func put<T: Encodable>(_ key: String, _ value: T?) throws {
        try c.encodeIfPresent(value, forKey: AnyKey(stringValue: key))
    }
}

struct Untagged {
    let c: KeyedDecodingContainer<AnyKey>
    let type: String

    init(_ decoder: any Decoder) throws {
        c = try decoder.container(keyedBy: AnyKey.self)
        type = try c.decode(String.self, forKey: AnyKey(stringValue: "type"))
    }

    func get<T: Decodable>(_ key: String) throws -> T { try c.decode(T.self, forKey: AnyKey(stringValue: key)) }
    func opt<T: Decodable>(_ key: String) throws -> T? { try c.decodeIfPresent(T.self, forKey: AnyKey(stringValue: key)) }
    func agent() throws -> AgentID { try opt("agent") ?? .main }

    func unknown() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Unknown type \(type)"))
    }
}

extension ChatEvent: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .sessionIdentified(let id):
            var t = try Tagged(encoder, "sessionIdentified")
            try t.put("id", id)
        case .titleChanged(let title):
            var t = try Tagged(encoder, "titleChanged")
            try t.put("title", title)
        case .controlsLoaded(let controls):
            var t = try Tagged(encoder, "controlsLoaded")
            try t.put("controls", controls)
        case .modeChanged(let change):
            var t = try Tagged(encoder, "modeChanged")
            try t.put("change", change)
        case .planModeChanged(let change):
            var t = try Tagged(encoder, "planModeChanged")
            try t.put("change", change)
        case .fastModeChanged(let report):
            var t = try Tagged(encoder, "fastModeChanged")
            try t.put("report", report)
        case .remoteControl(let remote):
            var t = try Tagged(encoder, "remoteControl")
            try t.put("remote", remote)
        case .remoteControlUnavailable(let reason):
            var t = try Tagged(encoder, "remoteControlUnavailable")
            try t.put("reason", reason)
        case .turnStarted(let turn, let origin, let at):
            var t = try Tagged(encoder, "turnStarted")
            try t.put("turn", turn)
            try t.put("origin", origin)
            try t.put("at", at)
        case .turnOrigin(let turn, let origin):
            var t = try Tagged(encoder, "turnOrigin")
            try t.put("turn", turn)
            try t.put("origin", origin)
        case .turnFinished(let turn, let outcome, let duration):
            var t = try Tagged(encoder, "turnFinished")
            try t.put("turn", turn)
            try t.put("outcome", outcome)
            try t.put("duration", duration)
        case .refused(let turn, let refusal):
            var t = try Tagged(encoder, "refused")
            try t.put("turn", turn)
            try t.put("refusal", refusal)
        case .turnChanges(let turn, let changes):
            var t = try Tagged(encoder, "turnChanges")
            try t.put("turn", turn)
            try t.put("changes", changes)
        case .queuedMessage(let id, let delivery):
            var t = try Tagged(encoder, "queuedMessage")
            try t.put("id", id)
            try t.put("delivery", delivery)
        case .messageQueued(let id, let text, let attachments):
            var t = try Tagged(encoder, "messageQueued")
            try t.put("id", id)
            try t.put("text", text)
            try t.put("attachments", attachments)
        case .userMessage(let text, let attachments, let id):
            var t = try Tagged(encoder, "userMessage")
            try t.put("text", text)
            try t.put("attachments", attachments)
            try t.put("id", id)
        case .peerMessage(let from, let text, let turn, let id):
            var t = try Tagged(encoder, "peerMessage")
            try t.put("from", from)
            try t.put("text", text)
            try t.put("turn", turn)
            try t.put("id", id)
        case .text(let block, let kind, let text, let agent):
            var t = try Tagged(encoder, "text")
            try t.put("block", block)
            try t.put("kind", kind)
            try t.put("text", text)
            try t.put("agent", agent.sub.map { _ in agent })
        case .finalAnswer(let block, let agent):
            var t = try Tagged(encoder, "finalAnswer")
            try t.put("block", block)
            try t.put("agent", agent.sub.map { _ in agent })
        case .toolStarted(let tool, let agent):
            var t = try Tagged(encoder, "toolStarted")
            try t.put("tool", tool)
            try t.put("agent", agent.sub.map { _ in agent })
        case .toolOutput(let id, let text, let agent):
            var t = try Tagged(encoder, "toolOutput")
            try t.put("id", id)
            try t.put("text", text)
            try t.put("agent", agent.sub.map { _ in agent })
        case .toolFinished(let id, let output, let isError, let agent):
            var t = try Tagged(encoder, "toolFinished")
            try t.put("id", id)
            try t.put("output", output)
            try t.put("isError", isError)
            try t.put("agent", agent.sub.map { _ in agent })
        case .toolStopped(let id, let agent):
            var t = try Tagged(encoder, "toolStopped")
            try t.put("id", id)
            try t.put("agent", agent.sub.map { _ in agent })
        case .fileChanged(let toolId, let changes, let agent):
            var t = try Tagged(encoder, "fileChanged")
            try t.put("toolId", toolId)
            try t.put("changes", changes)
            try t.put("agent", agent.sub.map { _ in agent })
        case .notice(let text, let isError):
            var t = try Tagged(encoder, "notice")
            try t.put("text", text)
            try t.put("isError", isError)
        case .agentSpawned(let info):
            var t = try Tagged(encoder, "agentSpawned")
            try t.put("info", info)
        case .agentProgress(let id, let progress):
            var t = try Tagged(encoder, "agentProgress")
            try t.put("id", id)
            try t.put("progress", progress)
        case .agentFinished(let id, let status, let result):
            var t = try Tagged(encoder, "agentFinished")
            try t.put("id", id)
            try t.put("status", status)
            try t.put("result", result)
        case .agentResumed(let id):
            var t = try Tagged(encoder, "agentResumed")
            try t.put("id", id)
        case .agentBackgrounded(let id):
            var t = try Tagged(encoder, "agentBackgrounded")
            try t.put("id", id)
        case .commandStarted(let command):
            var t = try Tagged(encoder, "commandStarted")
            try t.put("command", command)
        case .commandChanged(let id, let change):
            var t = try Tagged(encoder, "commandChanged")
            try t.put("id", id)
            try t.put("change", change)
        case .commandOutput(let id, let text):
            var t = try Tagged(encoder, "commandOutput")
            try t.put("id", id)
            try t.put("text", text)
        case .commandEnded(let id, let state, let at):
            var t = try Tagged(encoder, "commandEnded")
            try t.put("id", id)
            try t.put("state", state)
            try t.put("at", at)
        case .approvalRequested(let approval):
            var t = try Tagged(encoder, "approvalRequested")
            try t.put("approval", approval)
        case .approvalWithdrawn(let id):
            var t = try Tagged(encoder, "approvalWithdrawn")
            try t.put("id", id)
        case .planReady:
            _ = try Tagged(encoder, "planReady")
        case .exited(let status):
            var t = try Tagged(encoder, "exited")
            try t.put("status", status)
        case .compacted(let at, let from, let auto):
            var t = try Tagged(encoder, "compacted")
            try t.put("at", at)
            try t.put("from", from)
            try t.put("auto", auto)
        case .compactionStarted(let auto):
            var t = try Tagged(encoder, "compactionStarted")
            try t.put("auto", auto)
        case .compactionSummary(let text):
            var t = try Tagged(encoder, "compactionSummary")
            try t.put("text", text)
        case .compactionFailed(let reason):
            var t = try Tagged(encoder, "compactionFailed")
            try t.put("reason", reason)
        case .compactionStopped:
            _ = try Tagged(encoder, "compactionStopped")
        case .connection(let state):
            var t = try Tagged(encoder, "connection")
            try t.put("state", state)
        case .contextUsage(let usage):
            var t = try Tagged(encoder, "contextUsage")
            try t.put("usage", usage)
        case .earlierHistory(let more):
            var t = try Tagged(encoder, "earlierHistory")
            try t.put("more", more)
        case .replayed(let events):
            var t = try Tagged(encoder, "replayed")
            try t.put("events", events)
        case .historyReplaced(let events):
            var t = try Tagged(encoder, "historyReplaced")
            try t.put("events", events)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "sessionIdentified": self = .sessionIdentified(try u.get("id"))
        case "titleChanged": self = .titleChanged(try u.get("title"))
        case "controlsLoaded": self = .controlsLoaded(try u.get("controls"))
        case "modeChanged": self = .modeChanged(try u.get("change"))
        case "planModeChanged": self = .planModeChanged(try u.get("change"))
        case "fastModeChanged": self = .fastModeChanged(try u.get("report"))
        case "remoteControl": self = .remoteControl(try u.opt("remote"))
        case "remoteControlUnavailable": self = .remoteControlUnavailable(try u.opt("reason"))
        case "turnStarted": self = .turnStarted(try u.get("turn"), origin: try u.get("origin"), at: try u.get("at"))
        case "turnOrigin": self = .turnOrigin(try u.get("turn"), try u.get("origin"))
        case "turnFinished": self = .turnFinished(try u.opt("turn"), try u.get("outcome"), duration: try u.opt("duration"))
        case "refused": self = .refused(try u.get("turn"), try u.get("refusal"))
        case "turnChanges": self = .turnChanges(try u.get("turn"), try u.get("changes"))
        case "queuedMessage": self = .queuedMessage(id: try u.get("id"), try u.get("delivery"))
        case "messageQueued": self = .messageQueued(id: try u.get("id"), text: try u.get("text"), attachments: try u.opt("attachments") ?? [])
        case "userMessage": self = .userMessage(text: try u.get("text"), attachments: try u.opt("attachments") ?? [], id: try u.opt("id"))
        case "peerMessage": self = .peerMessage(from: try u.get("from"), text: try u.get("text"), turn: try u.opt("turn"), id: try u.opt("id"))
        case "text": self = .text(try u.get("block"), try u.get("kind"), try u.get("text"), agent: try u.agent())
        case "finalAnswer": self = .finalAnswer(try u.get("block"), agent: try u.agent())
        case "toolStarted": self = .toolStarted(try u.get("tool"), agent: try u.agent())
        case "toolOutput": self = .toolOutput(id: try u.get("id"), try u.get("text"), agent: try u.agent())
        case "toolFinished":
            self = .toolFinished(id: try u.get("id"), output: try u.opt("output"), isError: try u.opt("isError") ?? false, agent: try u.agent())
        case "toolStopped": self = .toolStopped(id: try u.get("id"), agent: try u.agent())
        case "fileChanged": self = .fileChanged(toolId: try u.get("toolId"), try u.get("changes"), agent: try u.agent())
        case "notice": self = .notice(try u.get("text"), isError: try u.opt("isError") ?? false)
        case "agentSpawned": self = .agentSpawned(try u.get("info"))
        case "agentProgress": self = .agentProgress(id: try u.get("id"), try u.get("progress"))
        case "agentFinished": self = .agentFinished(id: try u.get("id"), try u.get("status"), result: try u.opt("result"))
        case "agentResumed": self = .agentResumed(id: try u.get("id"))
        case "agentBackgrounded": self = .agentBackgrounded(id: try u.get("id"))
        case "commandStarted": self = .commandStarted(try u.get("command"))
        case "commandChanged": self = .commandChanged(id: try u.get("id"), try u.get("change"))
        case "commandOutput": self = .commandOutput(id: try u.get("id"), try u.get("text"))
        case "commandEnded": self = .commandEnded(id: try u.get("id"), try u.get("state"), at: try u.get("at"))
        case "approvalRequested": self = .approvalRequested(try u.get("approval"))
        case "approvalWithdrawn": self = .approvalWithdrawn(try u.get("id"))
        case "planReady": self = .planReady
        case "exited": self = .exited(status: try u.get("status"))
        case "compacted": self = .compacted(at: try u.get("at"), from: try u.opt("from"), auto: try u.opt("auto"))
        case "compactionStarted": self = .compactionStarted(auto: try u.get("auto"))
        case "compactionSummary": self = .compactionSummary(try u.get("text"))
        case "compactionFailed": self = .compactionFailed(try u.get("reason"))
        case "compactionStopped": self = .compactionStopped
        case "connection": self = .connection(try u.get("state"))
        case "contextUsage": self = .contextUsage(try u.get("usage"))
        case "earlierHistory": self = .earlierHistory(try u.get("more"))
        case "replayed": self = .replayed(Self.lossy(u, "events"))
        case "historyReplaced": self = .historyReplaced(Self.lossy(u, "events"))
        default: throw u.unknown()
        }
    }

    /// A history's events, those this side can't read left out.
    private static func lossy(_ u: Untagged, _ key: String) -> [ChatEvent] {
        let list: [Lossy]? = try? u.opt(key)
        return (list ?? []).compactMap(\.event)
    }

    private struct Lossy: Decodable {
        var event: ChatEvent?
        init(from decoder: any Decoder) throws { event = try? ChatEvent(from: decoder) }
    }
}

extension ChatCommand: Codable {
    package func encode(to encoder: any Encoder) throws {
        var t = try Tagged(encoder, name)
        switch self {
        case .send(let text, let files, let queued, let id):
            try t.put("text", text)
            try t.put("files", files)
            try t.put("queued", queued)
            try t.put("id", id)
        case .respond(let approval, let decision):
            try t.put("approval", approval)
            try t.put("decision", decision)
        case .setMode(let id), .setModel(let id), .stopAgent(let id), .stopCommand(let id), .backgroundCommand(let id), .commandOutput(let id),
            .agentHistory(let id):
            try t.put("id", id)
        case .setEffort(let level): try t.put("level", level)
        case .setPlanMode(let on), .setFastMode(let on), .watchCommands(let on), .setRemoteControl(let on): try t.put("on", on)
        case .rename(let title): try t.put("title", title)
        case .fork(let message, let text), .rollback(let message, let text), .unloadPoint(let message, let text):
            try t.put("message", message)
            try t.put("text", text)
        case .earlier(let turns): try t.put("turns", turns)
        case .unloaded(let earlier): try t.put("earlier", earlier)
        case .compact(let instructions): try t.put("instructions", instructions)
        case .useReset(let credit, let attempt):
            try t.put("credit", credit)
            try t.put("attempt", attempt)
        case .relaunch(let reason): try t.put("reason", reason)
        case .interrupt, .forkAtEnd, .earlierMessages, .usage, .listModels, .close, .unknown: break
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "send": self = .send(text: try u.get("text"), files: try u.opt("files") ?? [], queued: try u.opt("queued"), id: try u.opt("id"))
        case "interrupt": self = .interrupt
        case "respond": self = .respond(approval: try u.get("approval"), decision: try u.get("decision"))
        case "setMode": self = .setMode(try u.get("id"))
        case "setPlanMode": self = .setPlanMode(try u.get("on"))
        case "setModel": self = .setModel(try u.get("id"))
        case "setEffort": self = .setEffort(try u.get("level"))
        case "setFastMode": self = .setFastMode(try u.get("on"))
        case "rename": self = .rename(try u.get("title"))
        case "stopAgent": self = .stopAgent(try u.get("id"))
        case "stopCommand": self = .stopCommand(try u.get("id"))
        case "backgroundCommand": self = .backgroundCommand(try u.get("id"))
        case "commandOutput": self = .commandOutput(try u.get("id"))
        case "watchCommands": self = .watchCommands(try u.get("on"))
        case "agentHistory": self = .agentHistory(try u.get("id"))
        case "fork": self = .fork(message: try u.opt("message"), text: try u.get("text"))
        case "forkAtEnd": self = .forkAtEnd
        case "rollback": self = .rollback(message: try u.opt("message"), text: try u.get("text"))
        case "earlier": self = .earlier(turns: try u.opt("turns"))
        case "earlierMessages": self = .earlierMessages
        case "unloadPoint": self = .unloadPoint(message: try u.opt("message"), text: try u.get("text"))
        case "unloaded": self = .unloaded(to: try u.get("earlier"))
        case "compact": self = .compact(instructions: try u.opt("instructions") ?? "")
        case "usage": self = .usage
        case "useReset": self = .useReset(credit: try u.opt("credit"), attempt: try u.get("attempt"))
        case "setRemoteControl": self = .setRemoteControl(try u.get("on"))
        case "relaunch": self = .relaunch(reason: try u.opt("reason") ?? "")
        case "listModels": self = .listModels
        case "close": self = .close
        default: self = .unknown(u.type)
        }
    }
}

// MARK: - The enums inside them

extension AgentID: Codable {
    /// `{"sub": id}`; the chat's own agent is `{}`.
    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(sub, forKey: AnyKey(stringValue: "sub"))
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        self = try c.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "sub")).map(AgentID.sub) ?? .main
    }
}

extension ModeSource: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .session: _ = try Tagged(encoder, "session")
        case .user: _ = try Tagged(encoder, "user")
        case .refused: _ = try Tagged(encoder, "refused")
        case .agent(let cause, let agent):
            var t = try Tagged(encoder, "agent")
            try t.put("cause", cause)
            try t.put("agent", agent)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "session": self = .session
        case "user": self = .user
        case "refused": self = .refused
        case "agent": self = .agent(try u.opt("cause") ?? .other, try u.agent())
        default: throw u.unknown()
        }
    }
}

extension QueuedDelivery: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .inTurn(let after):
            var t = try Tagged(encoder, "inTurn")
            try t.put("after", after)
        case .nextTurn(let turn):
            var t = try Tagged(encoder, "nextTurn")
            try t.put("turn", turn)
        case .dropped: _ = try Tagged(encoder, "dropped")
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "inTurn": self = .inTurn(after: try u.opt("after"))
        case "nextTurn": self = .nextTurn(try u.get("turn"))
        case "dropped": self = .dropped
        default: throw u.unknown()
        }
    }
}

extension TurnOutcome: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .completed: _ = try Tagged(encoder, "completed")
        case .interrupted: _ = try Tagged(encoder, "interrupted")
        case .failed(let line):
            var t = try Tagged(encoder, "failed")
            try t.put("line", line)
        case .authFailed(let line):
            var t = try Tagged(encoder, "authFailed")
            try t.put("line", line)
        case .limited(let line, let resetsAt):
            var t = try Tagged(encoder, "limited")
            try t.put("line", line)
            try t.put("resetsAt", resetsAt)
        case .slept(let line):
            var t = try Tagged(encoder, "slept")
            try t.put("line", line)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed(try u.get("line"))
        case "authFailed": self = .authFailed(try u.get("line"))
        case "limited": self = .limited(try u.get("line"), resetsAt: try u.opt("resetsAt"))
        case "slept": self = .slept(try u.get("line"))
        // An outcome a newer side knows ends the turn as a failure, in its words.
        default: self = .failed(try u.opt("line") ?? u.type)
        }
    }
}

extension Connection: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .ok: _ = try Tagged(encoder, "ok")
        case .offline: _ = try Tagged(encoder, "offline")
        case .stalled: _ = try Tagged(encoder, "stalled")
        case .retrying(let attempt, let of):
            var t = try Tagged(encoder, "retrying")
            try t.put("attempt", attempt)
            try t.put("of", of)
        case .away(let words):
            var t = try Tagged(encoder, "away")
            try t.put("words", words)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "ok": self = .ok
        case "offline": self = .offline
        case "stalled": self = .stalled
        case "retrying": self = .retrying(attempt: try u.opt("attempt"), of: try u.opt("of"))
        case "away": self = .away(try u.get("words"))
        default: throw u.unknown()
        }
    }
}

extension Decision: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .allow: _ = try Tagged(encoder, "allow")
        case .allowAlways: _ = try Tagged(encoder, "allowAlways")
        case .deny: _ = try Tagged(encoder, "deny")
        case .keepPlanning: _ = try Tagged(encoder, "keepPlanning")
        case .approvePlan(let acceptEdits):
            var t = try Tagged(encoder, "approvePlan")
            try t.put("acceptEdits", acceptEdits)
        case .answers(let answers):
            var t = try Tagged(encoder, "answers")
            try t.put("answers", answers)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "allow": self = .allow
        case "allowAlways": self = .allowAlways
        case "deny": self = .deny
        case "keepPlanning": self = .keepPlanning
        case "approvePlan": self = .approvePlan(autoAcceptEdits: try u.opt("acceptEdits") ?? false)
        case "answers": self = .answers(try u.get("answers"))
        default: throw u.unknown()
        }
    }
}

extension RemoteControl.State: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .connecting: _ = try Tagged(encoder, "connecting")
        case .connected: _ = try Tagged(encoder, "connected")
        case .failed(let reason):
            var t = try Tagged(encoder, "failed")
            try t.put("reason", reason)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "connecting": self = .connecting
        case "connected": self = .connected
        case "failed": self = .failed(try u.get("reason"))
        default: throw u.unknown()
        }
    }
}

extension ActiveCommand.State: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .running: _ = try Tagged(encoder, "running")
        case .completed: _ = try Tagged(encoder, "completed")
        case .interrupted: _ = try Tagged(encoder, "interrupted")
        case .timedOut: _ = try Tagged(encoder, "timedOut")
        case .ended: _ = try Tagged(encoder, "ended")
        case .fired: _ = try Tagged(encoder, "fired")
        case .expired: _ = try Tagged(encoder, "expired")
        case .failed(let exit):
            var t = try Tagged(encoder, "failed")
            try t.put("exit", exit)
        case .stopped(let by):
            var t = try Tagged(encoder, "stopped")
            try t.put("by", by)
        case .deleted(let by):
            var t = try Tagged(encoder, "deleted")
            try t.put("by", by)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "running": self = .running
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "timedOut": self = .timedOut
        case "ended": self = .ended
        case "fired": self = .fired
        case "expired": self = .expired
        case "failed": self = .failed(exit: try u.opt("exit"))
        case "stopped": self = .stopped(by: try u.opt("by") ?? .unknown)
        case "deleted": self = .deleted(by: try u.opt("by") ?? .unknown)
        default: self = .ended
        }
    }
}

extension ActiveCommand.Output: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .none: _ = try Tagged(encoder, "none")
        case .stream: _ = try Tagged(encoder, "stream")
        case .file(let path):
            var t = try Tagged(encoder, "file")
            try t.put("path", path)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "file": self = .file(try u.get("path"))
        case "stream": self = .stream
        default: self = .none
        }
    }
}

extension CommandChange: Codable {
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .backgrounded(let at):
            var t = try Tagged(encoder, "backgrounded")
            try t.put("at", at)
        case .process(let process):
            var t = try Tagged(encoder, "process")
            try t.put("process", process)
        case .outputFile(let path):
            var t = try Tagged(encoder, "outputFile")
            try t.put("path", path)
        case .fired(let at, let next):
            var t = try Tagged(encoder, "fired")
            try t.put("at", at)
            try t.put("next", next)
        case .summary(let text):
            var t = try Tagged(encoder, "summary")
            try t.put("text", text)
        case .stopping: _ = try Tagged(encoder, "stopping")
        case .actionFailed(let line):
            var t = try Tagged(encoder, "actionFailed")
            try t.put("line", line)
        }
    }

    package init(from decoder: any Decoder) throws {
        let u = try Untagged(decoder)
        switch u.type {
        case "backgrounded": self = .backgrounded(at: try u.get("at"))
        case "process": self = .process(try u.get("process"))
        case "outputFile": self = .outputFile(try u.get("path"))
        case "fired": self = .fired(at: try u.get("at"), next: try u.opt("next"))
        case "summary": self = .summary(try u.get("text"))
        case "stopping": self = .stopping
        case "actionFailed": self = .actionFailed(try u.get("line"))
        default: throw u.unknown()
        }
    }
}
