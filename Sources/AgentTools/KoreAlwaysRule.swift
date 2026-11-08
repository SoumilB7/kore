import Foundation

/// "Always allow" on an Auto asks card (the owner via Kore-main, 2026-11-20): the kind of command,
/// not the one line, kept as a Claude `Bash(…)` allow rule. The rule's content is in claude 2.1's
/// own form (`git push *`: program and subcommand, the varying part a `*`); Kore's hook reads the
/// same allow rules and stops asking for what they cover, so the CLI's own flow runs it. Removals
/// of the working folder, its parents, a home or system path are never covered.
package enum KoreAlwaysRule {
    /// The rule an Always allow keeps for `command` (a `Bash(…)` rule's content); nil where Kore
    /// doesn't offer one (a critical removal, an empty line). `suggested`: the CLI's own rule
    /// contents, used when one is a prefix rule that covers the command.
    package static func rule(for command: String, cwd: String?, suggested: [String] = []) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !critical(line, cwd: cwd) else { return nil }
        if let theirs = suggested.first(where: { ($0.contains("*")) && covers($0, line) }) { return theirs }
        // A download into a shell is the download it names: that line only.
        if KoreAskList.pipesDownloadToShell(line) { return line }
        let segments = KoreAskList.segments(line).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let risky = segments.first { KoreAskList.reason(for: $0) != nil } ?? segments.first ?? line
        return kind(of: risky)
    }

    /// How a rule reads on the card: `sudo apt install …`.
    package static func shown(_ rule: String) -> String {
        var text = rule.hasSuffix(":*") ? String(rule.dropLast(2)) + " *" : rule
        if text.hasSuffix(" *") { text = String(text.dropLast()) + "…" }
        return text.replacingOccurrences(of: "*", with: "…")
    }

    /// Program and subcommand, the rest a `*`: `sudo apt install *`, `security find-generic-password *`,
    /// `rm -rf "$BUILD"/*`. A line with nothing that varies stays as it is.
    static func kind(of segment: String) -> String {
        let tokens = rawWords(segment)
        guard !tokens.isEmpty else { return segment }
        var index = 0
        // Leading `VAR=value`s stay as typed.
        while index < tokens.count, isAssignment(tokens[index]) { index += 1 }
        let sudo = index < tokens.count && unquoted(tokens[index]) == "sudo"
        if sudo {
            index += 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                let flag = tokens[index]
                index += 1
                if ["-u", "-g", "-h", "-p", "-C", "-D", "-U", "-r", "-t"].contains(flag), index < tokens.count { index += 1 }
            }
        }
        guard index < tokens.count else { return segment }
        let program = unquoted(tokens[index])
        index += 1
        if ["rm", "rmdir"].contains(program) {
            while index < tokens.count, tokens[index].hasPrefix("-") { index += 1 }
            let targets = Array(tokens[index...])
            guard targets.count == 1, let slash = targets[0].lastIndex(of: "/"), targets[0].index(after: slash) != targets[0].endIndex else {
                return segment
            }
            let head = tokens[..<index].joined(separator: " ")
            return head + " " + targets[0][...slash] + "*"
        }
        // Without sudo, a program whose argument is a file or process keeps the line as it is.
        if !sudo && fileTaking.contains(program) { return segment }
        if index < tokens.count, !fileTaking.contains(program), isSubcommand(tokens[index]) { index += 1 }
        guard index < tokens.count else { return tokens.joined(separator: " ") + " *" }
        return tokens[..<index].joined(separator: " ") + " *"
    }

    /// Programs whose first argument is what varies (a file, a process), not a subcommand.
    static let fileTaking: Set<String> = [
        "rm", "rmdir", "cat", "ls", "cp", "mv", "chmod", "chown", "chgrp", "touch", "mkdir", "kill", "killall", "pkill", "open",
        "echo", "head", "tail", "less", "more", "tee", "ln", "find", "grep", "sh", "bash", "zsh", "python", "python3", "node",
        "curl", "wget", "nano", "vi", "vim", "du", "df", "stat", "file", "xattr", "codesign", "spctl", "dd",
    ]

    static func isSubcommand(_ token: String) -> Bool {
        token.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
    }

    static func isAssignment(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }

    static func unquoted(_ token: String) -> String { token.filter { $0 != "\"" && $0 != "'" } }

    /// A simple command's words as typed (quotes kept), split at unquoted spaces.
    static func rawWords(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in segment {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: The floor

    /// A forced removal of the working folder or a folder above it, a home folder, or a system
    /// path (`sudo` or not): no Always rule covers it, and the hook asks whatever the rules say.
    package static func critical(_ command: String, cwd: String?) -> Bool {
        for segment in KoreAskList.segments(command) {
            var words = KoreAskList.words(segment)
            if words.first == "sudo" {
                words.removeFirst()
                while let first = words.first, first.hasPrefix("-") { words.removeFirst() }
            }
            guard let program = words.first, ["rm", "rmdir"].contains(program) else { continue }
            let arguments = Array(words.dropFirst())
            let flags = arguments.filter { $0.hasPrefix("-") }
            let forced = flags.contains { $0.hasPrefix("--") ? ["--recursive", "--force"].contains($0) : $0.dropFirst().contains { "rRf".contains($0) } }
            guard forced else { continue }
            for target in arguments where !target.hasPrefix("-") {
                if let why = KoreAskList.removal(flags + [target]), !why.contains("variable") { return true }
                let home = target.replacingOccurrences(of: "${HOME}", with: "$HOME")
                if ["$HOME", "$HOME/", "$HOME/*"].contains(home) { return true }
                if [".", "./", "..", "../", "*", "./*", "/*", "~/*", "../*"].contains(target) || target.allSatisfy({ $0 == "." || $0 == "/" }) {
                    return true
                }
                if let cwd, target.hasPrefix("/") {
                    let path = URL(fileURLWithPath: target).standardizedFileURL.path
                    let here = URL(fileURLWithPath: cwd).standardizedFileURL.path
                    if here == path || here.hasPrefix(path == "/" ? "/" : path + "/") { return true }
                }
            }
        }
        return false
    }

    // MARK: Rules

    /// A `Bash(…)` rule's content covers one command: `*` matches anything, a trailing ` *` (or the
    /// older `:*`) also the bare prefix; no `*`, the same line.
    package static func covers(_ content: String, _ command: String) -> Bool {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if content == "*" { return true }
        var pattern = content
        if pattern.hasSuffix(":*") { pattern = String(pattern.dropLast(2)) + " *" }
        guard pattern.contains("*") else { return pattern == line }
        var regex = "^"
        var rest = Substring(pattern)
        if pattern.hasSuffix(" *") { rest = rest.dropLast(2) }
        regex += rest.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        regex += pattern.hasSuffix(" *") ? "( .*)?$" : "$"
        return line.range(of: regex, options: .regularExpression) != nil
    }

    /// The command is allowed by one of `rules` (`Bash(…)` rule contents, `*` for all of Bash):
    /// the whole line by a rule without a wildcard, else each part Kore asks about by a rule of
    /// its own, as the CLI splits a line before it matches. Never a critical removal.
    package static func allowed(_ command: String, by rules: [String], cwd: String?) -> Bool {
        guard !rules.isEmpty, !critical(command, cwd: cwd) else { return false }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if rules.contains(where: { !$0.contains("*") && $0 == line } ) || rules.contains("*") { return true }
        if KoreAskList.pipesDownloadToShell(line) { return false }
        let risky = KoreAskList.segments(line).map { $0.trimmingCharacters(in: .whitespaces) }.filter { KoreAskList.reason(for: $0) != nil }
        guard !risky.isEmpty else { return false }
        return risky.allSatisfy { part in rules.contains { covers($0, part) } }
    }

    /// The `Bash` allow rules (their contents; `*` for a bare `Bash`) in the settings files the
    /// CLI reads: the project's `.claude/settings.local.json` and `.claude/settings.json`, and
    /// the user's `settings.json` (in `CLAUDE_CONFIG_DIR`, else `~/.claude`).
    package static func allowRules(projects: [String], configDirectory: String) -> [String] {
        var files = projects.flatMap { ["\($0)/.claude/settings.local.json", "\($0)/.claude/settings.json"] }
        files.append("\(configDirectory)/settings.json")
        var seen = Set<String>()
        return files.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }.flatMap(bashRules)
    }

    static func bashRules(in file: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file),
            let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let allow = (settings["permissions"] as? [String: Any])?["allow"] as? [Any]
        else { return [] }
        return allow.compactMap { entry in
            guard let rule = (entry as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
            if rule == "Bash" { return "*" }
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return nil }
            return String(rule.dropFirst(5).dropLast())
        }
    }
}
