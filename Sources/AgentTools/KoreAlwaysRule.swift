import Foundation

/// "Always allow" on a "Claude stopped" card (the owner via Kore-main, 2026-11-20 and 11-22): the
/// kind of command, not the one line, kept as a Claude `Bash(…)` allow rule in the project's local
/// settings (`keep`). The rule's content is in claude 2.1's own form (`git push *`: program and
/// subcommand, the varying part a `*`), which Claude's Auto honours. Removals of the working
/// folder, its parents, a home or system path are never covered.
package enum KoreAlwaysRule {
    /// The rule an Always allow keeps for `command` (a `Bash(…)` rule's content); nil where Kore
    /// doesn't offer one (a critical removal, an empty line). `suggested`: the CLI's own rule
    /// contents, used when one is a prefix rule that covers the command and the command is one
    /// whose kind may be a wildcard.
    package static func rule(for command: String, cwd: String?, suggested: [String] = []) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !critical(line, cwd: cwd) else { return nil }
        // A download into a shell is the download it names: that line only.
        if KoreAskList.pipesDownloadToShell(line) { return line }
        let judged = KoreAskList.judged(line, cwd: cwd, environment: ProcessInfo.processInfo.environment)
        let segments = judged.map { $0.segment.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let risky = judged.first { $0.why != nil }.map { $0.segment.trimmingCharacters(in: .whitespaces) } ?? segments.first ?? line
        let kind = kind(of: risky)
        // An exact kind stays exact, and the CLI's prefix rule is taken only when it is no wider
        // than Kore's kind (`git push:*` for `git push *`, never `sudo *`).
        guard kind.contains("*") else { return kind }
        return suggested.first { theirs in
            let text = theirs.hasSuffix(":*") ? String(theirs.dropLast(2)) + " *" : theirs
            return theirs.contains("*") && covers(theirs, line) && covers(kind, text)
        } ?? kind
    }

    /// How a rule reads on the card: `sudo apt install …`.
    package static func shown(_ rule: String) -> String {
        var text = rule.hasSuffix(":*") ? String(rule.dropLast(2)) + " *" : rule
        if text.hasSuffix(" *") { text = String(text.dropLast()) + "…" }
        return text.replacingOccurrences(of: "*", with: "…")
    }

    /// Program and subcommand, the rest a `*`: `sudo apt install *`, `security find-generic-password *`,
    /// `rm -rf "$BUILD"/*`. A line with nothing that varies stays as it is, and so does one whose
    /// wildcard would reach too far: a program that runs others or arbitrary code
    /// (`sudo bash x.sh`, not `sudo bash *`), one that writes any file under sudo, a removal
    /// from a folder near the top.
    static func kind(of segment: String) -> String {
        let tokens = rawWords(segment)
        guard !tokens.isEmpty else { return segment }
        var index = 0
        // Leading `VAR=value`s stay as typed.
        while index < tokens.count, isAssignment(tokens[index]) { index += 1 }
        guard index < tokens.count else { return segment }
        let sudo = KoreAskList.basename(unquoted(tokens[index])) == "sudo"
        if sudo {
            index += 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                let flag = tokens[index]
                index += 1
                if flag == "--" { break }
                if KoreAskList.sudoOptionsWithArgument.contains(flag), index < tokens.count { index += 1 }
            }
        }
        guard index < tokens.count else { return segment }
        let program = KoreAskList.basename(unquoted(tokens[index]))
        index += 1
        if ["rm", "rmdir", "unlink"].contains(program) {
            while index < tokens.count, tokens[index].hasPrefix("-") { index += 1 }
            let targets = Array(tokens[index...])
            guard targets.count == 1, let slash = targets[0].lastIndex(of: "/"), targets[0].index(after: slash) != targets[0].endIndex else {
                return segment
            }
            // `rm -rf /x` would keep `rm -rf /*`, `rm -rf ~/x` `rm -rf ~/*`: a folder that high
            // up (or one Kore can't place) keeps the line.
            if tooHigh(String(targets[0][..<slash])) { return segment }
            let head = tokens[..<index].joined(separator: " ")
            return head + " " + targets[0][...slash] + "*"
        }
        if runsOthers(program) || writesFiles.contains(program) { return segment }
        // Without sudo, a program whose argument is a file or process keeps the line as it is.
        if !sudo && fileTaking.contains(program) { return segment }
        // `security -q find-generic-password`: the verb after the program's own flags.
        if program == KoreAskList.keychainTool {
            while index < tokens.count, tokens[index].hasPrefix("-") { index += tokens[index] == "-p" ? 2 : 1 }
            index = min(index, tokens.count)
        }
        if index < tokens.count, !fileTaking.contains(program), isSubcommand(tokens[index]) { index += 1 }
        guard index < tokens.count else { return tokens.joined(separator: " ") + " *" }
        return tokens[..<index].joined(separator: " ") + " *"
    }

    /// A removal's folder whose `*` reaches a home or system path, or that Kore can't place.
    static func tooHigh(_ folder: String) -> Bool {
        let bare = unquoted(folder)
        if bare.isEmpty || bare == "." || bare == "~" || bare.hasPrefix("~") && !bare.contains("/") { return true }
        if bare.split(separator: "/").contains("..") || KoreAskList.isGlob(bare) { return true }
        if ["$HOME", "${HOME}"].contains(bare) { return true }
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : ["HOME": $0] } ?? [:]
        guard let path = KoreAskList.resolve(bare, known: home, here: nil) else { return false }
        return KoreAskList.pathReason(path, home: home["HOME"]) != nil
    }

    /// Programs that run other programs or arbitrary code: their kind is the exact line.
    static func runsOthers(_ program: String) -> Bool {
        if program.hasPrefix("python") || program.hasPrefix("pip") && program.count <= 4 { return true }
        return KoreAskList.shells.contains(program) || [
            "env", "xargs", "su", "sudo", "doas", "eval", "exec", "nohup", "timeout", "nice", "command", "builtin", "time", "find",
            "perl", "ruby", "node", "osascript", "awk", "gawk", "php", "lua", "deno", "bun", "vi", "vim", "nvim", "less", "ssh",
            "chroot", "watch", "script", "source", ".",
        ].contains(program)
    }

    /// Programs that write any file named on the line: under sudo a wildcard is any path.
    static let writesFiles: Set<String> = ["cp", "mv", "tee", "dd", "chmod", "chown", "chgrp", "ln", "install", "rsync", "truncate", "shred"]

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

    static func unquoted(_ token: String) -> String { token.filter { $0 != "\"" && $0 != "'" && $0 != "\\" } }

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
    /// path (`sudo` or not, through `env`, `xargs`, `sh -c`, `find -delete`, …, with the line's
    /// own variables read): no Always rule covers it, and the hook asks whatever the rules say.
    /// `environment`: where `HOME` and `TMPDIR` come from.
    package static func critical(
        _ command: String, cwd: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        KoreAskList.judged(command, cwd: cwd, environment: environment).contains { $0.critical }
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
    package static func allowed(
        _ command: String, by rules: [String], cwd: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !rules.isEmpty, !critical(command, cwd: cwd, environment: environment) else { return false }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if rules.contains(where: { !$0.contains("*") && $0 == line } ) || rules.contains("*") { return true }
        if KoreAskList.pipesDownloadToShell(line) { return false }
        let risky = KoreAskList.judged(line, cwd: cwd, environment: environment).filter { $0.why != nil }
            .map { $0.segment.trimmingCharacters(in: .whitespaces) }
        guard !risky.isEmpty else { return false }
        // A wildcard never stretches over `..`: `rm -rf build/*` doesn't reach `build/../..`.
        return risky.allSatisfy { part in rules.contains { covers($0, part) && ($0 == part || !part.contains("..")) } }
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

    /// Always allow on a "Claude stopped" card: `Bash(<rule>)` in the project's
    /// `.claude/settings.local.json`, as the CLI itself keeps one (the file's other settings and
    /// rules stay). claude 2.1.318 honours such a rule in Auto: Auto strips only broad ones
    /// (`Bash(*)`, `python:*`, `sudo *`), which Kore never writes.
    package static func keep(_ rule: String, project: String) throws {
        let folder = URL(fileURLWithPath: project).appendingPathComponent(".claude", isDirectory: true)
        let file = folder.appendingPathComponent("settings.local.json")
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file.path), !data.isEmpty {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
            }
            settings = read
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [Any] ?? []
        let entry = "Bash(\(rule))"
        guard !allow.contains(where: { ($0 as? String) == entry }) else { return }
        allow.append(entry)
        permissions["allow"] = allow
        settings["permissions"] = permissions
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
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
