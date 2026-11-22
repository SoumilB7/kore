import AgentTools
import Darwin
import Foundation
import KoreNet

// `kore`, the command inside Kore.app. Opening Kore or a folder, `kore setup` and `kore update` are the zsh
// script beside it (Resources/kore.zsh), run as they always were; the reads go to the running
// Kore over its agent channel, and `kore mcp` serves them to an agent as an MCP server.

let usage = """
    usage: kore                  open Kore
           kore <folder>         open a folder in Kore (kore . for this one)
           kore setup [claude|codex] [--verbose]
                                 install the agent CLIs that are missing
           kore update           update Kore to the latest version
           \(Reads.usage)
           kore logs [--since 10m] [--chat X] [--turn T] [--level warn] [-f] [--json] [log…]
                                 Kore's own logs, read from their files (Kore needn't run);
                                 the last hour unless --since says (--all: everything)
           kore mcp              the same reads as an MCP server, on stdio
           kore help             show this

    \(Reads.notes)
    A folder named like a command opens with a slash: kore ./ls
    """

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "help", "-h", "--help":
    print(usage)
case "logs":
    exit(Logs.run(Array(arguments.dropFirst())))
case "hook" where arguments.dropFirst().first == "pretool":
    // An Auto chat's PreToolUse hook: "ask" only for a Run once pass (`--once`), else nothing.
    exit(KoreAskList.runHook(Array(arguments.dropFirst(2))))
case "mcp":
    exit(MCPServer.run())
case "pipe":
    // rsync's remote shell for a copy to or from a box over KoreNet: Kore hands it the pipe.
    exit(PipeClient.run(Array(arguments.dropFirst())))
case let first? where Reads.names.contains(first):
    exit(Reads.run(first, Array(arguments.dropFirst()), unreachable: MCPServer.unreachableLine) { () throws(AgentFailure) in try AgentClient() })
default:
    openWithScript(arguments)
}

/// Hands opening Kore, folders, `kore setup` and `kore update` to the script.
func openWithScript(_ arguments: [String]) -> Never {
    let script: String
    if let path = ProcessInfo.processInfo.environment["KORE_SCRIPT"], !path.isEmpty {
        script = path
    } else {
        // Kore.app/Contents/Helpers/kore, however it was reached (~/.local/bin/kore is a link).
        var size = UInt32(MAXPATHLEN)
        var raw = [CChar](repeating: 0, count: Int(size))
        _ = _NSGetExecutablePath(&raw, &size)
        let me = URL(fileURLWithPath: String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
        script = me.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/kore.zsh").path
    }
    guard FileManager.default.isReadableFile(atPath: script) else {
        FileHandle.standardError.write(Data("kore: can't find the Kore app this came with\n".utf8))
        exit(1)
    }
    let argv = ["/bin/zsh", script] + arguments
    var cArgs = argv.map { strdup($0) } + [nil]
    execv("/bin/zsh", &cArgs)
    FileHandle.standardError.write(Data("kore: couldn't run zsh\n".utf8))
    exit(1)
}
