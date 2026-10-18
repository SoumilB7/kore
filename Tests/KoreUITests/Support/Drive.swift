import Foundation

@testable import KoreCore
@testable import KoreUI

/// Plays a cassette through a translator the way Kore does: each line Kore sent makes the calls
/// `Chat.send` and the backend make (the user's message shown, a turn opened, a stamped message
/// queued, `/compact` asked for), and each stdout line goes through the session's own mapping.
@MainActor
enum Drive {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-tests-work")

    /// Claude: every `ChatEvent` the cassette's run gives, in order.
    static func claude(_ name: String) throws -> [ChatEvent] {
        let cassette = try Cassette(name)
        let translator = ClaudeTranslator(folder: folder, sessionId: nil)
        var events: [ChatEvent] = []
        for line in cassette.lines {
            guard let message = line.json else { continue }
            if line.dir == "in" {
                guard message["type"]?.string == "user" else { continue }
                let text = message["message"]?["content"]?.string ?? ""
                if text == "/compact" { translator.compactRequested = true }
                if let queued = message["uuid"]?.string {
                    events.append(.messageQueued(id: queued, text: text, attachments: []))
                    translator.pendingQueued.insert(queued)
                } else {
                    events.append(.userMessage(text: text, attachments: []))
                    translator.openTurn(.user)
                }
            } else if line.dir == "out" {
                switch message["type"]?.string {
                case "control_response": continue
                case "control_cancel_request":
                    translator.translate(.permissionCancelled(requestId: message["request_id"]?.string ?? ""))
                case "control_request":
                    guard message["request"]?["subtype"]?.string == "can_use_tool" else { continue }
                    let id = message["request_id"]?.string ?? ""
                    translator.translate(.permissionRequest(PermissionRequest(id: id, message["request"] ?? .null)))
                default:
                    translator.translate(ClaudeEvent(message: message))
                }
            }
            events += translator.take().events
        }
        return events
    }

    /// Codex: the same through the app-server's mapping (`CodexSession`, `CodexBackend.send`).
    static func codex(_ name: String) throws -> [ChatEvent] {
        let cassette = try Cassette(name)
        let translator = CodexTranslator(folder: folder)
        var events: [ChatEvent] = []
        var thread: String?
        for line in cassette.lines {
            guard let message = line.json else { continue }
            if line.dir == "in" {
                let params = message["params"] ?? .null
                let text = params["input"]?.array?.first?["text"]?.string ?? ""
                switch message["method"]?.string {
                case "turn/start":
                    events.append(.userMessage(text: text, attachments: []))
                case "turn/steer":
                    let queued = params["clientUserMessageId"]?.string ?? ""
                    events.append(.messageQueued(id: queued, text: text, attachments: []))
                    translator.pendingSteer.insert(queued)
                case "thread/compact/start":
                    translator.compactRequested = true
                default: break
                }
            } else if line.dir == "out" {
                if thread == nil, let result = message["result"], let id = result["thread"]?["id"]?.string {
                    thread = id
                    translator.translate(.threadStarted(threadId: id, model: result["model"]?.string, raw: result))
                } else if let method = message["method"]?.string {
                    let params = message["params"] ?? .null
                    if let id = message["id"] {
                        if let approval = CodexApproval(id: id, method: method, params: params) {
                            translator.translate(.approvalRequest(approval))
                        }
                    } else if let other = params["threadId"]?.string, let thread, other != thread {
                        translator.translate(.subThread(threadId: other, method: method, params: params))
                    } else {
                        let event = CodexEvent(notification: method, params: params)
                        translator.translate(event)
                    }
                }
            }
            events += translator.take().events
        }
        return events
    }
}
