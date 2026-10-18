// Terminal harness for KoreCore: exercises the CLI wiring without any UI.
//
//   swift run kore-cli [--codex] [--cwd DIR] [--model M] [--effort E] [--mode MODE] [--resume ID] [--debug]
//   swift run kore-cli --history [--cwd DIR]     list both CLIs' past sessions for the folder
//
// Claude modes: default, acceptEdits, plan, auto, dontAsk, bypassPermissions
// Codex modes:  readOnly, askForApproval, approveForMe, fullAccess (+ /plan, /default)
//
// Type a message to send it. /interrupt, /mode <mode>, /model <name>, /models (codex), /quit.
// While a permission prompt is open, the next line answers it.

import Foundation
import KoreCore

var codex = false, debug = false, history = false
var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var model: String?, effort: String?, mode: String?, resume: String?

var argv = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argv.next() {
    switch arg {
    case "--codex": codex = true
    case "--debug": debug = true
    case "--history": history = true
    case "--cwd": cwd = URL(fileURLWithPath: argv.next() ?? ".")
    case "--model": model = argv.next()
    case "--effort": effort = argv.next()
    case "--mode": mode = argv.next()
    case "--resume": resume = argv.next()
    default: fail("unknown argument \(arg)")
    }
}

if history, let resume {
    for message in ClaudeHistory.messages(sessionId: resume, in: cwd) {
        let content = message["message"]?["content"]
        let summary = content?.string ?? content?.array?.map { $0["type"]?.string ?? "?" }.joined(separator: ",") ?? "?"
        out("\(message["type"]?.string ?? "?")  \(summary.prefix(90))\n")
    }
    exit(0)
}
if history {
    let codexThreads = (try? await CodexHistory.threads(in: cwd)) ?? []
    for session in (ClaudeHistory.sessions(in: cwd) + codexThreads).sorted(by: { $0.updated > $1.updated }) {
        out("\(session.agent.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(session.updated.formatted(date: .abbreviated, time: .shortened))  \(session.title)  \(dim)\(session.id)\(reset)\n")
    }
    exit(0)
}

if codex {
    var options = CodexSession.Options(cwd: cwd, model: model, effort: effort, resume: resume)
    if let mode {
        guard let m = CodexSession.Permissions(rawValue: mode) else {
            fail("codex modes: \(CodexSession.Permissions.allCases.map(\.rawValue))")
        }
        options.permissions = m
    }
    await runCodex(options, debug: debug)
} else {
    var options = ClaudeSession.Options(cwd: cwd, model: model, effort: effort, resume: resume)
    if let mode {
        guard let m = ClaudeSession.PermissionMode(rawValue: mode) else {
            fail("claude modes: \(ClaudeSession.PermissionMode.allCases.map(\.rawValue))")
        }
        options.permissionMode = m
    }
    await runClaude(options, debug: debug)
}
