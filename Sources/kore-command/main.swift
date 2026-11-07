import Darwin
import Foundation

// `kore`, the command inside Kore.app. Opening Kore or a folder and `kore setup` are the zsh
// script beside it (Resources/kore.zsh), run as they always were; the reads go to the running
// Kore over its agent channel, and `kore mcp` serves them to an agent as an MCP server.

let usage = """
    usage: kore                  open Kore
           kore <folder>         open a folder in Kore (kore . for this one)
           kore setup [claude|codex] [--verbose]
                                 install the agent CLIs that are missing
           kore ls               the open chats
           kore show <chat>      one chat: state, model, context, waiting cards
           kore log <chat> [-n N] [-f]
                                 its last rows; -f follows it
           kore pending [<chat>] cards waiting on you
           kore history [--folder F] [--search Q] [--archived]
                                 a window's past chats
           kore whoami           who Kore sees calling, and its access
           kore caps             what that access allows
           kore mcp              the same reads as an MCP server, on stdio
           kore help             show this

    A chat is its title (any part only it has), its short id, or . for the chat this runs in.
    Every read takes --json. A folder named like a command opens with a slash: kore ./ls
    """

let arguments = Array(CommandLine.arguments.dropFirst())
let reads: Set = ["ls", "show", "log", "pending", "history", "whoami", "caps", "mcp"]

switch arguments.first {
case "help", "-h", "--help":
    print(usage)
case let first? where reads.contains(first):
    exit(Reads.run(first, Array(arguments.dropFirst())))
default:
    openWithScript(arguments)
}

/// Hands opening Kore, folders and `kore setup` to the script, which has always done them.
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
