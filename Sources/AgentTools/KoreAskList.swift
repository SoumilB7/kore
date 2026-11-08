import Foundation

/// The calls an Auto chat asks a person about before Auto's own check sees them (the owner via
/// Kore-main, 2026-11-19; z-docs/design/cli-wiring.md, "Auto asks"): Kore's PreToolUse hook
/// (`kore hook pretool`, `kore-host hook pretool`) answers "ask" for these, so the person answers
/// in place and the chat goes on with the real result. Everything else gets no decision, and the
/// classifier decides as before. Text only: no network, no model, fast.
package enum KoreAskList {
    /// Why a Bash command is on the list; nil when it isn't.
    /// `environment`: the variables a removal's path may name besides the ones the line sets
    /// itself (only `HOME` and `TMPDIR` are taken from it).
    package static func reason(for command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let command = withoutHeredocData(command)
        if pipesDownloadToShell(command) { return "a download piped into a shell" }
        var known = Dictionary(uniqueKeysWithValues: ["HOME", "TMPDIR"].compactMap { name in
            environment[name].flatMap { $0.isEmpty ? nil : (name, $0) }
        })
        for segment in segments(command) {
            assign(segment, into: &known)
            let words = words(segment)
            guard let first = words.first else { continue }
            if first == "sudo" { return "sudo" }
            if ["rm", "rmdir"].contains(first), let why = removal(Array(words.dropFirst()), known: known) { return why }
            if first == "security", let verb = words.dropFirst().first, keychainReads.contains(verb) { return "a Keychain read" }
        }
        return nil
    }

    /// The line without the text of its heredocs: `cat > run.sh <<'EOF' … EOF` writes words, it
    /// doesn't run them. A heredoc a shell (or ssh) reads is kept: that one runs.
    static func withoutHeredocData(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        let runners: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "ssh", "sudo", "eval", "source", "."]
        var kept: [Substring] = []
        var ends: [(word: String, tabs: Bool)] = []
        var skipping = false
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = ends.first {
                let text = end.tabs ? String(line.drop { $0 == "\t" }) : String(line)
                if text.trimmingCharacters(in: .whitespaces) == end.word { ends.removeFirst() }
                if !skipping { kept.append(line) }
                if ends.isEmpty { skipping = false }
                continue
            }
            kept.append(line)
            let opened = heredocs(in: String(line))
            guard !opened.isEmpty else { continue }
            ends = opened
            // Kept when anything on the line runs a shell: `bash <<EOF`, `cat <<EOF | sh`.
            skipping = !segments(String(line)).contains { runners.contains(words($0).first ?? "") }
        }
        return kept.joined(separator: "\n")
    }

    /// The end words of the heredocs a line opens (`<<EOF`, `<<-'END'`, `<< "X"`), in order;
    /// `<<<` (a here-string) opens none.
    static func heredocs(in line: String) -> [(word: String, tabs: Bool)] {
        var found: [(String, Bool)] = []
        var rest = Substring(line)
        while let range = rest.range(of: "<<") {
            var after = rest[range.upperBound...]
            if after.first == "<" { rest = after.drop { $0 == "<" }; continue }
            let tabs = after.first == "-"
            if tabs { after = after.dropFirst() }
            after = after.drop { $0 == " " }
            let word = after.prefix { !$0.isWhitespace && !";|&<>()".contains($0) }
            let name = word.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
            if !name.isEmpty { found.append((String(name), tabs)) }
            rest = after.dropFirst(word.count)
        }
        return found
    }

    /// The variables a simple command sets for what follows: `T=/tmp/x`, `export OUT="$TMPDIR/o"`.
    /// A value Kore can't read for sure (a command substitution, an unknown variable, a stray
    /// quote) forgets the name, so a path that uses it still asks.
    static func assign(_ segment: String, into known: inout [String: String]) {
        // Split at blanks outside quotes, quotes kept: `G="$HOME/App Support/x"` is one token.
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in segment {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == " " || character == "\t" {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        if let first = tokens.first, ["export", "local", "declare", "typeset", "readonly"].contains(first) { tokens.removeFirst() }
        for token in tokens {
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { break }
            let name = String(token[..<equals])
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !(name.first?.isNumber ?? true) else { break }
            let raw = String(token[token.index(after: equals)...])
            let quotes = raw.filter { $0 == "\"" }.count, singles = raw.filter { $0 == "'" }.count
            guard quotes % 2 == 0, singles % 2 == 0 else { known[name] = nil; continue }
            var value = raw.filter { $0 != "\"" }
            if raw.hasPrefix("'") { value = raw.filter { $0 != "'" }; known[name] = value; continue }
            value = value.filter { $0 != "'" }
            if value == "~" || value.hasPrefix("~/"), let home = known["HOME"] { value = home + value.dropFirst() }
            known[name] = expand(value, known)
        }
    }

    /// `text` with its `$NAME`, `${NAME}` and `${NAME:-word}` filled in from `known`; nil when any
    /// part can't be (an unknown name, `$1`, `$(…)`, a backtick).
    static func expand(_ text: String, _ known: [String: String]) -> String? {
        if text.contains("`") { return nil }
        var out = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            var after = rest[rest.index(after: dollar)...]
            if after.first == "{" {
                guard let close = after.firstIndex(of: "}") else { return nil }
                let inner = after[after.index(after: after.startIndex)..<close]
                if inner.contains("$") || inner.contains("{") { return nil }
                let name = inner.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                let tail = inner.dropFirst(name.count)
                if let value = known[String(name)], !(tail.hasPrefix(":-") && value.isEmpty) {
                    out += value
                } else if tail.hasPrefix(":-") || tail.hasPrefix("-") {
                    out += tail.drop { $0 == ":" }.dropFirst()
                } else {
                    return nil
                }
                if tail.isEmpty == false, !(tail.hasPrefix(":-") || tail.hasPrefix("-")) { return nil }
                after = after[after.index(after: close)...]
            } else {
                let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !name.isEmpty, !(name.first?.isNumber ?? true), let value = known[String(name)] else { return nil }
                out += value
                after = after.dropFirst(name.count)
            }
            rest = after
        }
        return out + rest
    }

    /// The hook's answer for one call (the PreToolUse input): its JSON when it asks, else nil.
    /// Only in Auto: other modes ask by themselves. `rules`: the settings' `Bash` allow rules
    /// (`KoreAlwaysRule.allowRules`, read only for a call on the list): a call they allow gets no
    /// decision, so the CLI's own flow runs it, except a critical removal.
    package static func answer(_ input: [String: Any], rules: (() -> [String])? = nil) -> [String: Any]? {
        guard input["permission_mode"] as? String == "auto", input["tool_name"] as? String == "Bash",
            let command = (input["tool_input"] as? [String: Any])?["command"] as? String, let why = reason(for: command)
        else { return nil }
        if let rules, KoreAlwaysRule.allowed(command, by: rules(), cwd: input["cwd"] as? String) { return nil }
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
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let answer = answer(input, rules: { settingsRules(input, environment: ProcessInfo.processInfo.environment) }),
            let out = try? JSONSerialization.data(withJSONObject: answer)
        else { return 0 }
        FileHandle.standardOutput.write(out)
        return 0
    }

    /// The allow rules a hook sees: the project's (`CLAUDE_PROJECT_DIR`, and the call's `cwd`)
    /// and the user's (`CLAUDE_CONFIG_DIR`, else `~/.claude`), as the CLI that runs it reads them.
    package static func settingsRules(_ input: [String: Any], environment: [String: String]) -> [String] {
        let projects = [environment["CLAUDE_PROJECT_DIR"], input["cwd"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        return KoreAlwaysRule.allowRules(projects: projects, configDirectory: config)
    }

    static let keychainReads: Set<String> = [
        "find-generic-password", "find-internet-password", "dump-keychain", "export", "find-certificate", "find-identity",
    ]

    static let systemRoots = ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Users", "/Volumes"]

    /// rm or rmdir with -r or -f (or their long forms) on a variable, the home folder, or a system
    /// path.
    /// `known`: variables whose values Kore read from the same line (and `HOME`, `TMPDIR`); a path
    /// made only of those is checked as the path it is, any other variable asks.
    static func removal(_ arguments: [String], known: [String: String] = [:]) -> String? {
        let flags = arguments.filter { $0.hasPrefix("-") }
        let forced =
            flags.contains { $0.hasPrefix("--") ? ["--recursive", "--force"].contains($0) : $0.dropFirst().contains { "rRf".contains($0) } }
        guard forced else { return nil }
        for written in arguments.filter({ !$0.hasPrefix("-") }) {
            var target = written
            if written.contains("$") || written.contains("`") {
                guard let path = expand(written, known), !path.contains("$") else { return "a forced removal of a path held in a variable" }
                target = path
            }
            if let why = literal(target) { return why }
            // `dir/*` empties dir: as risky as removing it.
            if target.hasSuffix("/*"), target.count > 2, let why = literal(String(target.dropLast(2))) { return why }
        }
        return nil
    }

    /// Why removing this path (as written, no variables) is on the list.
    static func literal(_ target: String) -> String? {
        if target == "~" || target.hasPrefix("~/") && target.split(separator: "/").count <= 2 || target == "~/" {
            return "a forced removal in your home folder"
        }
        let path = target.hasSuffix("/") && target.count > 1 ? String(target.dropLast()) : target
        if path.hasPrefix("/Users/") && path.split(separator: "/").count <= 2 { return "a forced removal of a home folder" }
        if path == "/" || systemRoots.contains(path) || path == "/*" { return "a forced removal of a system path" }
        if systemRoots.dropFirst().contains(where: { path.hasPrefix($0 + "/") }) && path.split(separator: "/").count <= 2 {
            return "a forced removal of a system path"
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
