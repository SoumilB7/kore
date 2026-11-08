import Foundation

/// The calls an Auto chat asks a person about before Auto's own check sees them (the owner via
/// Kore-main, 2026-11-19; z-docs/design/cli-wiring.md, "Auto asks"): Kore's PreToolUse hook
/// (`kore hook pretool`, `kore-host hook pretool`) answers "ask" for these, so the person answers
/// in place and the chat goes on with the real result. Everything else gets no decision, and the
/// classifier decides as before. Text only: no network, no model, fast.
package enum KoreAskList {
    /// Why a Bash command is on the list; nil when it isn't.
    package static func reason(for command: String) -> String? {
        if pipesDownloadToShell(command) { return "a download piped into a shell" }
        for segment in segments(command) {
            let words = words(segment)
            guard let first = words.first else { continue }
            if first == "sudo" { return "sudo" }
            if ["rm", "rmdir"].contains(first), let why = removal(Array(words.dropFirst())) { return why }
            if first == "security", let verb = words.dropFirst().first, keychainReads.contains(verb) { return "a Keychain read" }
        }
        return nil
    }

    /// The hook's answer for one call (the PreToolUse input): its JSON when it asks, else nil.
    /// Only in Auto: other modes ask by themselves.
    package static func answer(_ input: [String: Any]) -> [String: Any]? {
        guard input["permission_mode"] as? String == "auto", input["tool_name"] as? String == "Bash",
            let command = (input["tool_input"] as? [String: Any])?["command"] as? String, let why = reason(for: command)
        else { return nil }
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse", "permissionDecision": "ask",
                "permissionDecisionReason": "Kore asks you first: \(why).",
            ]
        ]
    }

    /// `kore hook pretool`: the hook's whole run. The call on stdin, the answer (or nothing) on
    /// stdout; anything it can't read gets no decision, so the CLI goes on as without it.
    package static func runHook() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let answer = answer(input),
            let out = try? JSONSerialization.data(withJSONObject: answer)
        else { return 0 }
        FileHandle.standardOutput.write(out)
        return 0
    }

    static let keychainReads: Set<String> = [
        "find-generic-password", "find-internet-password", "dump-keychain", "export", "find-certificate", "find-identity",
    ]

    static let systemRoots = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Users", "/Volumes"]

    /// rm or rmdir with -r or -f (or their long forms) on a variable, the home folder, or a system
    /// path.
    static func removal(_ arguments: [String]) -> String? {
        let flags = arguments.filter { $0.hasPrefix("-") }
        let forced =
            flags.contains { $0.hasPrefix("--") ? ["--recursive", "--force"].contains($0) : $0.dropFirst().contains { "rRf".contains($0) } }
        guard forced else { return nil }
        for target in arguments.filter({ !$0.hasPrefix("-") }) {
            if target.contains("$") || target.contains("`") { return "a forced removal of a path held in a variable" }
            if target == "~" || target.hasPrefix("~/") && target.split(separator: "/").count <= 2 || target == "~/" {
                return "a forced removal in your home folder"
            }
            let path = target.hasSuffix("/") && target.count > 1 ? String(target.dropLast()) : target
            if path.hasPrefix("/Users/") && path.split(separator: "/").count <= 2 { return "a forced removal of a home folder" }
            if path == "/" || systemRoots.contains(path) || path == "/*" { return "a forced removal of a system path" }
            if systemRoots.dropFirst().contains(where: { path.hasPrefix($0 + "/") }) && path.split(separator: "/").count <= 2 {
                return "a forced removal of a system path"
            }
        }
        return nil
    }

    /// curl or wget whose output goes into a shell: `curl … | sh`, `bash <(curl …)`, `sh -c "$(curl …)"`.
    static func pipesDownloadToShell(_ command: String) -> Bool {
        let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
        let downloads = ["curl", "wget"]
        let pipes = command.components(separatedBy: "|")
        if pipes.count > 1 {
            for (index, part) in pipes.enumerated().dropLast() where downloads.contains(words(part).first ?? "") {
                if let next = words(pipes[index + 1]).first, shells.contains(next) || next == "sudo" { return true }
            }
        }
        for shell in shells where command.contains("\(shell) <(") || command.contains("\(shell) -c \"$(") || command.contains("\(shell) -c '$(") {
            if downloads.contains(where: { command.contains($0) }) { return true }
        }
        return false
    }

    /// A command line's simple commands, split at `&&`, `||`, `;`, `|` and newlines.
    static func segments(_ command: String) -> [String] {
        var parts = [command]
        for separator in ["&&", "||", ";", "|", "\n"] { parts = parts.flatMap { $0.components(separatedBy: separator) } }
        return parts
    }

    /// A simple command's words, quotes taken off, leading `VAR=value`s and `env`, `command`,
    /// `nohup`, `time` dropped.
    static func words(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in segment {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        while let first = words.first, first.contains("=") && !first.hasPrefix("-") || ["env", "command", "nohup", "time", "exec"].contains(first) {
            words.removeFirst()
        }
        return words
    }
}
