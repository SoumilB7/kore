import Foundation
import KoreCore

func runClaude(_ options: ClaudeSession.Options, debug: Bool) async {
    do {
        let auth = try await ClaudeAuth.status(executable: options.executable)
        guard auth.loggedIn else { fail("claude CLI is not logged in. Run `claude auth login`, then try again.") }
        out("\(dim)claude: \(auth.email ?? "?") · \(auth.authMethod ?? "?") · \(auth.subscriptionType ?? "-")\(reset)\n")
    } catch {
        fail("could not read claude auth status: \(error)")
    }

    let session: ClaudeSession
    do { session = try await ClaudeSession.start(options) } catch { fail("failed to start: \(error)") }
    let prompts = PromptQueue<PermissionRequest>()

    let eventLoop = Task {
        for await event in session.events {
            switch event {
            case .sessionStarted(let info):
                out("\(dim)session \(info.sessionId) · \(info.model ?? "?") · \(info.permissionMode ?? "?")\(reset)\n> ")
            case .textDelta(let text, nil):
                out(text)
            case .thinkingDelta(let text, nil):
                out("\(dim)\(text)\(reset)")
            case .assistant(_, let blocks, nil):
                for case .toolUse(_, let name, let input) in blocks {
                    out("\n\(bold)⏺ \(name)\(reset)\(dim) \(input.compact.prefix(160))\(reset)\n")
                }
            case .user(let blocks, nil):
                for case .toolResult(_, let content, let isError) in blocks {
                    let text = content.string ?? content[0]?["text"]?.string ?? content.compact
                    let first = text.split(separator: "\n").first.map(String.init) ?? ""
                    out("\(dim)  ⎿ \(isError ? "error: " : "")\(first.prefix(160))\(reset)\n")
                }
            case .permissionRequest(let request):
                await prompts.push(request)
                if request.isQuestion {
                    for q in request.input["questions"]?.array ?? [] {
                        out("\n\(yellow)? \(q["question"]?.string ?? "")\(reset)\n")
                        for (i, o) in (q["options"]?.array ?? []).enumerated() {
                            out("  \(i + 1). \(o["label"]?.string ?? "")\(dim) \(o["description"]?.string ?? "")\(reset)\n")
                        }
                    }
                    out("\(yellow)answer (number or text; separate multiple questions with |):\(reset) ")
                } else {
                    out("\n\(yellow)? allow \(request.toolName)\(reset) \(request.description ?? String(request.input.compact.prefix(200)))\n")
                    out("\(yellow)[y]es / [a]lways / [n]o:\(reset) ")
                }
            case .permissionCancelled(let id):
                await prompts.remove(id)
                out("\(dim)(permission request withdrawn)\(reset)\n")
            case .turnCompleted(let r):
                let cost = r.costUSD.map { String(format: "$%.4f", $0) } ?? "-"
                out("\n\(dim)— \(r.subtype) · \(r.durationMs ?? 0)ms · \(cost)\(reset)\n> ")
            case .stderr(let s):
                if debug { FileHandle.standardError.write(Data("\(dim)\(s)\(reset)".utf8)) }
            case .raw(let json):
                if debug && json["type"]?.string != "stream_event" {
                    out("\(dim)[\(json["type"]?.string ?? "?")] \(json.compact.prefix(200))\(reset)\n")
                }
            case .exited(let status):
                out("\n\(dim)claude exited (\(status))\(reset)\n")
                exit(status)
            default:
                break  // subagent (parentToolUseId != nil) traffic
            }
        }
    }

    for await line in inputLines() {
        do {
            if let request = await prompts.pop() {
                try await session.respond(to: request, claudeDecision(for: request, line: line))
            } else if line == "/quit" {
                break
            } else if line == "/interrupt" {
                try await session.interrupt()
            } else if line.hasPrefix("/mode ") {
                guard let mode = ClaudeSession.PermissionMode(rawValue: String(line.dropFirst(6))) else {
                    out("modes: \(ClaudeSession.PermissionMode.allCases.map(\.rawValue))\n> ")
                    continue
                }
                try await session.setPermissionMode(mode)
                out("\(dim)mode → \(mode.rawValue)\(reset)\n> ")
            } else if line.hasPrefix("/model ") {
                try await session.setModel(String(line.dropFirst(7)))
                out("\(dim)model → \(line.dropFirst(7))\(reset)\n> ")
            } else if !line.isEmpty {
                try await session.send(line)
            }
        } catch {
            out("error: \(error)\n> ")
        }
    }

    await session.close()
    await eventLoop.value
}

private func claudeDecision(for request: PermissionRequest, line: String) -> PermissionDecision {
    if request.isQuestion {
        let questions = request.input["questions"]?.array ?? []
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var answers: [String: String] = [:]
        for (q, part) in zip(questions, parts) {
            let labels = q["options"]?.array?.compactMap { $0["label"]?.string } ?? []
            answers[q["question"]?.string ?? ""] = pickOption(part, from: labels)
        }
        return .answers(answers)
    }
    switch line.lowercased() {
    case "y", "yes": return .allow
    case "a", "always": return .allowAlways
    default: return .deny(message: "The user denied this tool call.")
    }
}
