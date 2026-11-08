import Darwin
import Foundation

// `kore`, the command inside Kore.app. Opening Kore or a folder, `kore setup` and `kore update` are the zsh
// script beside it (Resources/kore.zsh), run as they always were; the reads go to the running
// Kore over its agent channel, and `kore mcp` serves them to an agent as an MCP server.

let usage = """
    usage: kore                  open Kore
           kore <folder>         open a folder in Kore (kore . for this one)
           kore setup [claude|codex] [--verbose]
                                 install the agent CLIs that are missing
           kore update           update Kore to the latest version
           kore ls               the open chats
           kore show <chat>      one chat: state, model, context, waiting cards
           kore log <chat> [-n N] [-f]
                                 its last rows; -f follows it
           kore pending [<chat>] cards waiting on you
           kore history [--folder F] [--search Q] [--archived]
                                 a window's past chats
           kore options          what Act limited may set on this chat now
           kore rename <name>    rename this chat
           kore model <model>    switch this chat's model
           kore effort <level>   set its effort
           kore fast on|off      its fast mode
           kore mode <mode>      lower its mode (only you raise one)
           kore compact          compact it, once this turn ends
           kore new [--claude|--codex] [--model M] [--mode X] ["message"]
                                 a new chat in this window, in front (Act unlimited)
           kore fork <chat> [--at -N|<message>] [--claude|--codex] [--model M] ["message"]
                                 fork a chat (. for this one) into a tab in front (Act unlimited)
           kore wait <chat> [--timeout s]
                                 until its turn ends or a card asks: its answer
           kore ask <short id> "question"
                                 ask another Act unlimited chat; kore wait --ask <id> for the answer
           kore reply <ask id> "answer" [file]
                                 answer an ask this chat was asked, a file of its folder with it
           kore fetch <device:path | path>
                                 copy a file from an open folder into .kore/inbox/ (50 MB, no secrets)
           kore send <chat> "message"
                                 send to another chat, queued while it works
           kore stop <chat>      stop its turn
           kore tab <chat>       bring its tab to the front
           kore open <session> [--folder F]
                                 open a past chat (kore history lists them) in front
           kore close <short id> close a chat as its tab's close does; History keeps it
           kore answer <chat> <card> <answer>... | --deny | --allow
                                 answer a question card, one answer per question
           kore logs [--since 10m] [--chat X] [--turn T] [--level warn] [-f] [--json] [log…]
                                 Kore's own logs, read from their files (Kore needn't run);
                                 the last hour unless --since says (--all: everything)
           kore whoami           who Kore sees calling, and its access
           kore caps             what that access allows
           kore mcp              the same reads as an MCP server, on stdio
           kore help             show this

    Act limited's commands change the chat they run in, or with Act unlimited a chat named first:
    kore model <chat> <model>. Act unlimited reaches the chats it can read at or below this chat's mode.
    A chat is its title (any part only it has), its short id, or . for the chat this runs in.
    Every read takes --json. A folder named like a command opens with a slash: kore ./ls
    """

let arguments = Array(CommandLine.arguments.dropFirst())
let reads: Set = [
    "ls", "show", "log", "pending", "history", "whoami", "caps", "mcp", "options", "rename", "model", "effort", "fast", "mode", "compact", "new", "fork",
    "send", "stop", "tab", "answer", "wait", "open", "close", "ask", "reply", "fetch",
]

switch arguments.first {
case "help", "-h", "--help":
    print(usage)
case "logs":
    exit(Logs.run(Array(arguments.dropFirst())))
case let first? where reads.contains(first):
    exit(Reads.run(first, Array(arguments.dropFirst())))
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
