import Foundation
import KoreCore

func runCodex(_ options: CodexSession.Options, debug: Bool) async {
    do {
        let auth = try await CodexAuth.status(executable: options.executable)
        guard auth.loggedIn else { fail("codex CLI is not logged in. Run `codex login`, then try again.") }
        out("\(dim)codex: \(auth.email ?? "?") · \(auth.type ?? "?") · \(auth.planType ?? "-")\(reset)\n")
    } catch {
        fail("could not read codex auth status: \(error)")
    }

    let session: CodexSession
    do { session = try await CodexSession.start(options) } catch { fail("failed to start: \(error)") }
    let prompts = PromptQueue<CodexApproval>()

    let eventLoop = Task {
        for await event in session.events {
            switch event {
            case .threadStarted(let threadId, let model, _):
                out("\(dim)thread \(threadId) · \(model ?? "?") · \(options.permissions.rawValue)\(options.plan ? " · plan" : "")\(reset)\n> ")
            case .textDelta(_, let text):
                out(text)
            case .reasoningDelta(_, let text):
                out("\(dim)\(text)\(reset)")
            case .planDelta(_, let text):
                out("\(yellow)\(text)\(reset)")
            case .itemStarted(let item) where item.type == "commandExecution":
                out("\n\(bold)⏺ \(item.command ?? "command")\(reset)\n")
            case .itemStarted(let item) where item.type == "fileChange":
                let paths = item.raw["changes"]?.array?.compactMap { $0["path"]?.string } ?? []
                out("\n\(bold)⏺ edit\(reset)\(dim) \(paths.joined(separator: ", "))\(reset)\n")
            case .itemCompleted(let item) where item.type == "commandExecution":
                out("\(dim)  ⎿ \(item.status ?? "") · exit \(item.exitCode.map(String.init) ?? "-")\(reset)\n")
            case .itemCompleted(let item) where item.type == "agentMessage":
                out("\n")
            case .approvalRequest(let approval):
                await prompts.push(approval)
                switch approval.kind {
                case .userInput:
                    for q in approval.questions {
                        out("\n\(yellow)? \(q["question"]?.string ?? "")\(reset)\n")
                        for (i, o) in (q["options"]?.array ?? []).enumerated() {
                            out("  \(i + 1). \(o["label"]?.string ?? "")\(dim) \(o["description"]?.string ?? "")\(reset)\n")
                        }
                    }
                    out("\(yellow)answer (number or text; separate multiple questions with |):\(reset) ")
                default:
                    let what = approval.command ?? approval.reason ?? approval.params.compact
                    out("\n\(yellow)? allow \(approval.kind)\(reset) \(what.prefix(200))\n")
                    out("\(yellow)[y]es / [a]lways (this session) / [n]o:\(reset) ")
                }
            case .approvalResolved(let id):
                await prompts.remove(id)
            case .turnCompleted(let r):
                let error = r.errorMessage.map { " · \($0.prefix(200))" } ?? ""
                out("\(dim)— \(r.status) · \(r.durationMs ?? 0)ms\(error)\(reset)\n> ")
            case .error(let message, let willRetry):
                out("\n\(yellow)error\(willRetry ? " (retrying)" : ""):\(reset) \(message.prefix(300))\n")
            case .stderr(let s):
                if debug { FileHandle.standardError.write(Data("\(dim)\(s)\(reset)".utf8)) }
            case .raw(let method, let params):
                if debug { out("\(dim)[\(method)] \(params.compact.prefix(200))\(reset)\n") }
            case .subThread(let thread, let method, _):
                if debug { out("\(dim)[sub \(thread.suffix(6))] \(method)\(reset)\n") }
            case .exited(let status):
                out("\n\(dim)codex exited (\(status))\(reset)\n")
                exit(status)
            default:
                break
            }
        }
    }

    for await line in inputLines() {
        do {
            if let approval = await prompts.pop() {
                try await session.respond(to: approval, codexDecision(for: approval, line: line))
            } else if line == "/quit" {
                break
            } else if line == "/interrupt" {
                try await session.interrupt()
            } else if line == "/models" {
                let models = try await session.models().compactMap { $0["id"]?.string }
                out("\(models.joined(separator: "\n"))\n> ")
            } else if line.hasPrefix("/mode ") {
                guard let permissions = CodexSession.Permissions(rawValue: String(line.dropFirst(6))) else {
                    out("modes: \(CodexSession.Permissions.allCases.map(\.rawValue))\n> ")
                    continue
                }
                await session.setPermissions(permissions)
                out("\(dim)permissions → \(permissions.rawValue) (from next turn)\(reset)\n> ")
            } else if line == "/plan" || line == "/default" {
                await session.setPlanMode(line == "/plan")
                out("\(dim)\(line == "/plan" ? "plan mode on" : "plan mode off") (from next turn)\(reset)\n> ")
            } else if line.hasPrefix("/model ") {
                await session.setModel(String(line.dropFirst(7)))
                out("\(dim)model → \(line.dropFirst(7)) (from next turn or /compact)\(reset)\n> ")
            } else if line == "/compact" {
                try await session.compact()
                out("\(dim)compacting on \(await session.threadModel ?? "?")\(reset)\n")
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

private func codexDecision(for approval: CodexApproval, line: String) -> CodexDecision {
    if approval.kind == .userInput {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var answers: [String: [String]] = [:]
        for (q, part) in zip(approval.questions, parts) {
            let labels = q["options"]?.array?.compactMap { $0["label"]?.string } ?? []
            answers[q["id"]?.string ?? ""] = [pickOption(part, from: labels)]
        }
        return .answers(answers)
    }
    switch line.lowercased() {
    case "y", "yes": return .accept
    case "a", "always": return .acceptForSession
    default: return .decline
    }
}
