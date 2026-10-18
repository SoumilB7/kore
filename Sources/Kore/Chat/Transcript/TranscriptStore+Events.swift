import AppKit
import Foundation

/// The transcript's side of `ChatEvent`: content, turns and sub-agents. Session, control and
/// approval events belong to other stores and pass through untouched.
extension TranscriptStore {
    func apply(_ event: ChatEvent) {
        switch event {
        case .replayed(let events):
            batch { events.forEach(apply) }

        case .turnStarted(let id, _, let at):
            turnStarted(id, at: at)
        case .turnFinished(let id, let outcome, let duration):
            let outcome: Outcome = switch outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed(let message): .failed(message)
            }
            turnFinished(id, outcome, duration: duration.map(Self.seconds))
        case .turnChanges(let id, let changes):
            turnChanges(id, changes)

        case .userMessage(let text, let attachments):
            user(text, attachments: attachments.map(Self.attachment))
        case .peerMessage(let from, let text, let turn):
            peer(from: from, text: text, turn: turn)
        case .text(let block, let kind, let text, let agent):
            let kind: TextKind = switch kind {
            case .answer: .answer
            case .thinking: .thinking
            case .plan: .plan
            }
            self.text(block, kind, text, agent: agent.sub)
        case .finalAnswer(let block, let agent):
            if agent == .main { finalAnswer(block: block) }
        case .toolStarted(let call, let agent):
            toolStarted(
                id: call.id, name: call.name, detail: call.detail, input: call.input, summary: call.description,
                path: call.path, agent: agent.sub)
        case .toolOutput(let id, let text, _):
            toolOutput(id: id, text)
        case .toolFinished(let id, let output, let isError, _):
            toolFinished(id: id, output: output, isError: isError)
        case .fileChanged(let id, let changes, _):
            fileChanged(tool: id, changes)
        case .notice(let text, let isError):
            notice(text, isError: isError)

        case .agentSpawned(let info):
            agentSpawned(
                id: info.id, name: info.name, type: info.type, model: info.model, prompt: info.prompt,
                background: info.background,
                tool: info.toolId, parent: info.parent.sub)
        case .agentProgress(let id, let p):
            agentProgress(id: id, tokens: p.tokens, tools: p.tools, lastTool: p.lastTool, duration: p.duration.map(Self.seconds))
        case .agentFinished(let id, let status, let result):
            let status: AgentInfo.Status = switch status {
            case .completed: .finished
            case .failed: .failed
            case .stopped: .stopped
            }
            agentFinished(id: id, status: status, result: result)

        case .exited(let status):
            if turnIsOpen { turnFinished(nil, .interrupted) }
            if status != 0 && status != 15 { notice("\(providerName) exited (\(status))", isError: true) }

        case .approvalRequested(let approval):
            if case .sub(let agent) = approval.agent { agentAsked(approval.id, agent: agent) }
        case .approvalWithdrawn(let id):
            approvalSettled(id)

        case .sessionIdentified, .titleChanged, .controlsLoaded, .modeChanged, .planModeChanged, .turnOrigin,
            .planReady:
            break
        }
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let (s, atto) = d.components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }

    private static func attachment(_ a: SentAttachment) -> Attachment {
        if let url = a.url, FileManager.default.fileExists(atPath: url.path) { return Attachment(url: url) }
        return Attachment(name: a.name, kind: a.kind, thumbnail: a.image.flatMap(NSImage.init(data:)))
    }
}

extension AgentID {
    /// The sub-agent's id; nil for the chat's own agent.
    var sub: String? {
        if case .sub(let id) = self { return id }
        return nil
    }
}

