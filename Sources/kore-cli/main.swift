// Terminal harness for KoreCore: exercises the CLI wiring without any UI.
//
//   swift run kore-cli [--codex] [--cwd DIR] [--model M] [--effort E] [--mode MODE] [--resume ID] [--debug]
//   swift run kore-cli --history [--cwd DIR]     list both CLIs' past sessions for the folder
//   swift run kore-cli --archive|--unarchive ID [--cwd DIR]   archive a Codex thread (Codex's own archive)
//   swift run kore-cli [--codex] --import FILE [--cwd DIR] [--model M]   import a chat's history file into a new
//                                    chat of this CLI, print what was carried, then continue it
//   swift run kore-cli [--codex] --preview FILE [--model M]   what an import would carry, its time and peak
//                                    memory; nothing is written
//
// Claude modes: default, acceptEdits, plan, auto, dontAsk, bypassPermissions
// Codex modes:  readOnly, askForApproval, approveForMe, fullAccess (+ /plan, /default)
//
// Type a message to send it. /interrupt, /mode <mode>, /model <name>, /models (codex), /compact (codex), /quit.
// While a permission prompt is open, the next line answers it.

import Foundation
import KoreCore

var codex = false, debug = false, history = false
var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var model: String?, effort: String?, mode: String?, resume: String?, archive: (id: String, on: Bool)?, importFile: String?
var previewFile: String?

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
    case "--archive": archive = (argv.next() ?? "", true)
    case "--unarchive": archive = (argv.next() ?? "", false)
    case "--import": importFile = argv.next()
    case "--preview": previewFile = argv.next()
    default: fail("unknown argument \(arg)")
    }
}

if let archive {
    do {
        if archive.on { try await CodexHistory.archive(archive.id, in: cwd) }
        else { try await CodexHistory.unarchive(archive.id, in: cwd) }
    } catch { fail(String(describing: error)) }
    exit(0)
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
        out("\(session.agent.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(session.updated.formatted(date: .abbreviated, time: .shortened))  \(session.title)\(session.archived ? "  [archived]" : "")  \(dim)\(session.id)\(reset)\n")
    }
    exit(0)
}

if let previewFile {
    guard let writer = HandoffWriters.writer(codex ? "codex" : "claude") else { fail("no writer") }
    let began = ContinuousClock.now
    let result = HandoffImport.inspect(URL(fileURLWithPath: previewFile), for: writer, model: model)
    let took = ContinuousClock.now - began
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    switch result {
    case .success(let p):
        out("\(p.product) · \(p.turns.map(String.init) ?? "?") turns · \(p.full) full, \(p.condensed) condensed, \(p.bare) bare, \(p.notCarried)\(p.turns == nil ? "+" : "") not carried\(p.summary ? ", summary" : "") · ~\(p.tokens) of \(p.budget) tokens\n")
    case .failure(let why):
        out("not importable: \(why)\n")
    }
    out("preview \(took) · peak memory \(usage.ru_maxrss / (1 << 20)) MB\n")
    exit(0)
}

if let importFile {
    let file = URL(fileURLWithPath: importFile)
    guard let writer = HandoffWriters.writer(codex ? "codex" : "claude") else { fail("no writer") }
    guard let identity = HandoffFormats.identify(file) else { fail("not a chat Kore can import") }
    guard let (segment, plan) = HandoffImport.plan(file, for: writer, model: model) else { fail("nothing importable in \(file.lastPathComponent)") }
    out("\(dim)\(identity.product) \(segment.sessionId) · \(segment.turns.count) turns: \(plan.count(.full)) full, \(plan.count(.condensed)) condensed, \(plan.count(.bare)) bare, \(plan.notCarried) not carried\(plan.summary == nil ? "" : ", summary") · ~\(plan.tokens) of \(plan.budget) tokens\(reset)\n")
    let target = HandoffTarget(
        folder: cwd, title: segment.shownTitle, model: model, effort: effort, mode: mode ?? (codex ? "askForApproval" : "default"),
        planMode: false, instructions: HandoffWriters.instructions(for: writer, in: cwd))
    do {
        let record = try await HandoffImport.write(segment, plan, file: file, into: target, writer: writer)
        resume = record.target.session
        out("\(dim)imported as \(writer.product) \(record.target.session)\(record.written.isEmpty ? "" : " (\(record.written.count) rows)")\(reset)\n")
    } catch {
        fail("couldn't import: \(error)")
    }
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
