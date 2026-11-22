import Foundation

/// Kore's reading of a shell line (which commands a line runs, what a removal reaches) and its
/// PreToolUse hook (`kore hook pretool`, `kore-host hook pretool`). Since 0.3.7 Kore keeps no
/// list of its own (the owner via Kore-main, 2026-11-22; z-docs/design/cli-wiring.md, "Auto
/// stops"): Claude's own Auto check is the only judge, and the hook answers "ask" only for a
/// one-time pass the person gave (`Pass`, Run once on a "Claude stopped" card), so the CLI asks in
/// place and Kore answers allow. The reading serves `KoreAlwaysRule` (a rule's kind, the critical
/// floor). Text only: no network, no model, fast.
package enum KoreAskList {
    /// Why a Bash command is risky to Kore's reading (the kind `KoreAlwaysRule` keeps comes from
    /// its first risky part); nil when nothing is.
    /// `environment`: the variables a removal's path may name besides the ones the line sets
    /// itself (only `HOME` and `TMPDIR` are taken from it). `cwd`: the folder it runs in, for
    /// relative paths; nil leaves them as written.
    package static func reason(
        for command: String, environment: [String: String] = ProcessInfo.processInfo.environment, cwd: String? = nil
    ) -> String? {
        if pipesDownloadToShell(command) { return downloadReason }
        return judged(command, cwd: cwd, environment: environment).lazy.compactMap(\.why).first
    }

    static let downloadReason = "a download piped into a shell"
    static let criticalReason = "a forced removal of the working folder, a folder above it, a home folder or a system path"
    static let unseenReason = "a removal of paths Kore can't see"

    /// A one-time pass (Run once): exactly this command, in this chat, once, until then (`cwd`:
    /// where it was refused, for the record). It rides the
    /// hook's command line (`--once <base64 JSON>`), so the hook needs no file and no state.
    package struct Pass: Codable, Equatable, Sendable {
        package let command: String
        package let cwd: String
        /// Seconds since 1970.
        package let until: Double

        package init(command: String, cwd: String, until: Date) {
            self.command = command
            self.cwd = cwd
            self.until = until.timeIntervalSince1970
        }

        /// The hook's argument for it.
        package var argument: String { ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }

        package init?(argument: String) {
            guard let data = Data(base64Encoded: argument), let pass = try? JSONDecoder().decode(Pass.self, from: data) else { return nil }
            self = pass
        }

        /// The call is this pass's command, before it expires: in any folder of the chat, so a `cd`
        /// between the refusal and the retry doesn't stop it (the pass rides only that chat's CLI).
        package func covers(_ command: String, at now: Date) -> Bool {
            now.timeIntervalSince1970 < until && command == self.command
        }
    }

    package static let passReason = "Run once: you allowed this command once."

    /// The hook's answer for one call (the PreToolUse input): "ask" for a pass's command, so the
    /// CLI asks in place and Kore answers allow; nil (no decision, Claude's own check decides)
    /// for anything else. Only in Auto.
    package static func answer(_ input: [String: Any], passes: [Pass], now: Date = Date()) -> [String: Any]? {
        guard input["permission_mode"] as? String == "auto", input["tool_name"] as? String == "Bash",
            let command = (input["tool_input"] as? [String: Any])?["command"] as? String,
            passes.contains(where: { $0.covers(command, at: now) })
        else { return nil }
        return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": passReason]]
    }

    /// `kore hook pretool [--once <pass>]…`: the hook's whole run. The call on stdin, the answer (or
    /// nothing) on stdout; anything it can't read gets no decision, so the CLI goes on as without it.
    package static func runHook(_ arguments: [String] = []) -> Int32 {
        var passes: [Pass] = []
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            if flag == "--once", let value = rest.popFirst(), let pass = Pass(argument: value) { passes.append(pass) }
        }
        // Read whole even without a pass: the CLI writes the call either way.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !passes.isEmpty, let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let answer = answer(input, passes: passes),
            let out = try? JSONSerialization.data(withJSONObject: answer)
        else { return 0 }
        FileHandle.standardOutput.write(out)
        return 0
    }

    // MARK: Judging a line

    /// One simple command of a line, as the list judges it: why it asks (nil: it doesn't), and
    /// whether it is a critical removal (`KoreAlwaysRule.critical`).
    struct Judged {
        let segment: String
        let why: String?
        let critical: Bool
    }

    /// Each simple command of `command` judged in order, with the variables and `cd`s before it.
    /// `cwd`: the working folder (critical: it and the folders above it).
    static func judged(_ command: String, cwd: String?, environment: [String: String]) -> [Judged] {
        var known = Dictionary(uniqueKeysWithValues: ["HOME", "TMPDIR"].compactMap { name in
            environment[name].flatMap { $0.isEmpty ? nil : (name, $0) }
        })
        let cwd = cwd.flatMap { $0.hasPrefix("/") ? normalized($0) : nil }
        return judged(command, cwd: cwd, here: cwd, known: &known, depth: 0)
    }

    static func judged(_ command: String, cwd: String?, here start: String?, known: inout [String: String], depth: Int) -> [Judged] {
        var here = start
        var out: [Judged] = []
        for part in parts(command) {
            assign(part.text, into: &known)
            let simple = simple(part.text)
            if let simple, simple.program == "cd" {
                let target = simple.arguments.first { !$0.hasPrefix("-") } ?? "~"
                here = target == "-" ? nil : resolve(target, known: known, here: here).flatMap { $0.hasPrefix("/") ? $0 : nil }
            }
            let (why, critical) = judge(simple, known: known, here: here, cwd: cwd, depth: depth)
            out.append(Judged(segment: part.text, why: why, critical: critical))
        }
        return out
    }

    /// Why one simple command asks, and whether it is critical.
    static func judge(_ c: Simple?, known: [String: String], here: String?, cwd: String?, depth: Int) -> (String?, Bool) {
        guard let c else { return (nil, false) }
        var why: String? = c.sudo ? "sudo" : nil
        var critical = false
        switch c.program {
        case "rm", "rmdir", "unlink":
            let (flags, targets) = removalArguments(c.arguments)
            let isForced = forced(flags)
            why = why ?? removal(targets, forced: isForced, known: known, here: here)
            if isForced { critical = targets.contains { criticalTarget($0, known: known, here: here, cwd: cwd) } }
        case "find":
            let found = findRemoval(c.arguments)
            if found.sudo { why = why ?? "sudo" }
            if found.removes {
                why = why ?? removal(found.paths, forced: true, known: known, here: here)
                // What a test picks inside the folder goes, not the folder.
                if !found.filtered { critical = found.paths.contains { criticalTarget($0, known: known, here: here, cwd: cwd) } }
            }
        case "security":
            var rest = c.arguments[...]
            while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst(flag == "-p" ? 2 : 1) }
            if let verb = rest.first, keychainReads.contains(verb) { why = why ?? "a Keychain read" }
        default:
            // A script a shell, `eval` or `su -c` runs is judged as the line it is.
            guard depth < 4, let script = script(of: c) else { break }
            var inner = known
            let found = judged(script, cwd: cwd, here: here, known: &inner, depth: depth + 1)
            why = why ?? (pipesDownloadToShell(script) ? downloadReason : found.lazy.compactMap(\.why).first)
            critical = found.contains { $0.critical }
        }
        return (why, critical)
    }

    /// The script `sh -c '…'`, `su -c '…'` or `eval …` runs.
    static func script(of c: Simple) -> String? {
        if c.program == "eval" { return c.arguments.isEmpty ? nil : c.arguments.joined(separator: " ") }
        if c.program == "su", let index = c.arguments.firstIndex(where: { $0 == "-c" || $0 == "--command" }), index + 1 < c.arguments.count {
            return c.arguments[index + 1]
        }
        guard shells.contains(c.program) else { return nil }
        var command = false
        for argument in c.arguments {
            if argument.hasPrefix("--") { continue }
            if argument.hasPrefix("-") {
                if argument.dropFirst().contains("c") { command = true }
                continue
            }
            return command ? argument : nil
        }
        return nil
    }

    // MARK: Simple commands

    /// A simple command with what only wraps it taken off: leading `VAR=value`s, shell keywords
    /// (`then`, `do`, `{`), `env`, `nice`, `timeout`, `nohup`, `time`, `command`, `exec`,
    /// `xargs`, and `sudo`/`doas` with their options (`sudo` says they were there).
    struct Simple {
        /// The program as written (`/bin/rm`), quotes and backslashes off.
        let path: String
        /// Its basename: `rm`.
        let program: String
        let arguments: [String]
        let sudo: Bool
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "mksh", "ash"]
    static let keywords: Set<String> = ["if", "then", "do", "else", "elif", "while", "until", "!", "{", "}", "time", "builtin"]
    /// sudo's options that take an argument (`-u root`).
    static let sudoOptionsWithArgument: Set<String> = [
        "-u", "-g", "-h", "-p", "-C", "-D", "-U", "-r", "-t", "-T", "-R", "--user", "--group", "--host", "--prompt", "--close-from",
        "--chdir", "--other-user", "--role", "--type", "--command-timeout", "--chroot",
    ]

    static func simple(_ segment: String) -> Simple? {
        var w = words(segment)[...]
        var sudo = false
        while let first = w.first {
            if isAssignment(first) || keywords.contains(first) { w = w.dropFirst(); continue }
            let base = basename(first)
            switch base {
            case "sudo", "doas":
                sudo = true
                w = w.dropFirst()
                let withArgument: Set<String> = base == "sudo" ? sudoOptionsWithArgument : ["-u", "-C"]
                while let flag = w.first, flag.hasPrefix("-") {
                    w = w.dropFirst()
                    if flag == "--" { break }
                    if withArgument.contains(flag) { w = w.dropFirst() }
                }
                if w.isEmpty { return Simple(path: first, program: base, arguments: [], sudo: true) }
            case "env":
                w = w.dropFirst()
                while let flag = w.first, flag.hasPrefix("-") || isAssignment(flag) {
                    w = w.dropFirst()
                    if flag == "--" { break }
                    if ["-S", "--split-string"].contains(flag), let string = w.first {
                        w = (words(string) + w.dropFirst())[...]
                        break
                    }
                    if ["-u", "--unset", "-C", "--chdir", "-P"].contains(flag) { w = w.dropFirst() }
                }
            case "nice":
                w = w.dropFirst()
                while let flag = w.first, flag.hasPrefix("-") {
                    w = w.dropFirst()
                    if flag == "-n" || flag == "--adjustment" { w = w.dropFirst() }
                }
            case "timeout":
                w = w.dropFirst()
                while let flag = w.first, flag.hasPrefix("-") {
                    w = w.dropFirst()
                    if ["-s", "-k", "--signal", "--kill-after"].contains(flag) { w = w.dropFirst() }
                }
                w = w.dropFirst()  // the duration
            case "nohup", "exec", "command":
                if base == "command", w.dropFirst().first.map({ $0 == "-v" || $0 == "-V" }) == true { return nil }
                w = w.dropFirst()
                while let flag = w.first, flag.hasPrefix("-") {
                    w = w.dropFirst()
                    if base == "exec" && flag == "-a" { w = w.dropFirst() }
                }
            case "xargs":
                w = w.dropFirst()
                while let flag = w.first, flag.hasPrefix("-") {
                    w = w.dropFirst()
                    if flag == "--" { break }
                    if ["-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "-R", "-S", "-J"].contains(flag) { w = w.dropFirst() }
                }
            default:
                return Simple(path: first, program: base, arguments: withoutRedirects(Array(w.dropFirst())), sudo: sudo)
            }
        }
        return nil
    }

    /// Words without their redirections: `> /dev/null`, `2>&1`, `<<EOF`.
    static func withoutRedirects(_ words: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for word in words {
            if skip { skip = false; continue }
            if let range = word.range(of: "^[0-9]*(&>>|&>|>>|>&|>\\||<<<|<<-|<<|<&|<>|>|<)", options: .regularExpression) {
                if range.upperBound == word.endIndex { skip = true }
                continue
            }
            out.append(word)
        }
        return out
    }

    static func basename(_ word: String) -> String {
        guard let slash = word.lastIndex(of: "/"), word.index(after: slash) != word.endIndex else { return word }
        return String(word[word.index(after: slash)...])
    }

    static func isAssignment(_ word: String) -> Bool {
        word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }

    /// A simple command's words, quotes and backslashes taken off (`r\m` is `rm`).
    static func words(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                escaped = false
            } else if quote == "'" {
                if character == "'" { quote = nil } else { current.append(character) }
            } else if character == "\\" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: Splitting a line

    /// A line's simple commands, split at `&&`, `||`, `;`, `|`, `&`, newlines, `(` and `)`
    /// outside quotes. The text of a `$(…)`, `` `…` `` or `<(…)` stays in its command and is
    /// also a command of its own; a heredoc's data is left out (`documents`).
    package static func segments(_ command: String) -> [String] { parts(command).map(\.text) }

    /// One simple command and the pipeline it is in: the commands `|` joins share one.
    struct Part {
        let text: String
        let pipeline: Int
    }

    static func parts(_ command: String) -> [Part] {
        var out: [Part] = []
        var counter = 0
        for document in documents(command) { scanned(document, into: &out, counter: &counter) }
        return out
    }

    /// The parts of text with no heredoc in it.
    static func scanned(_ text: String, into out: inout [Part], counter: inout Int) {
        var index = 0
        scan(Array(text), &index, closer: nil, out: &out, counter: &counter)
    }

    private static func scan(_ c: [Character], _ i: inout Int, closer: Character?, out: inout [Part], counter: inout Int) {
        var current = ""
        var pipeline = counter
        counter += 1
        var quote: Character?
        var depth = 0
        func flush() {
            if current.contains(where: { !$0.isWhitespace }) { out.append(Part(text: current, pipeline: pipeline)) }
            current = ""
        }
        func newPipeline() {
            pipeline = counter
            counter += 1
        }
        func substitution(skip: Int, until end: Character) {
            let start = i
            i += skip
            scan(c, &i, closer: end, out: &out, counter: &counter)
            if i < c.count { i += 1 }
            current += String(c[start..<min(i, c.count)])
        }
        func arithmetic() {
            let start = i
            var level = 0
            while i < c.count {
                if c[i] == "(" {
                    level += 1
                } else if c[i] == ")" {
                    level -= 1
                    if level == 0 { i += 1; break }
                }
                i += 1
            }
            current += String(c[start..<min(i, c.count)])
        }
        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if quote == "'" {
                current.append(ch)
                if ch == "'" { quote = nil }
                i += 1
                continue
            }
            if ch == "\\" {
                current.append(ch)
                if let next { current.append(next) }
                i += 2
                continue
            }
            if ch == "`" {
                if closer == "`" { flush(); return }
                substitution(skip: 1, until: "`")
                continue
            }
            if ch == "$", next == "(" {
                if i + 2 < c.count, c[i + 2] == "(" { arithmetic() } else { substitution(skip: 2, until: ")") }
                continue
            }
            if quote == "\"" {
                current.append(ch)
                if ch == "\"" { quote = nil }
                i += 1
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
                i += 1
            case "<" where next == "(", ">" where next == "(":
                substitution(skip: 2, until: ")")
            case "#" where current.last.map(\.isWhitespace) ?? true:
                while i < c.count, c[i] != "\n" { i += 1 }
            case "(":
                if next == "(", !current.contains(where: { !$0.isWhitespace }) {
                    arithmetic()
                } else {
                    depth += 1
                    flush()
                    i += 1
                }
            case ")":
                if depth == 0, closer == ")" { flush(); return }
                depth = max(0, depth - 1)
                flush()
                i += 1
            case ";", "\n":
                flush()
                newPipeline()
                i += 1
            case "&":
                if next == "&" {
                    flush()
                    newPipeline()
                    i += 2
                } else if current.last == ">" || current.last == "<" || next == ">" {
                    current.append(ch)
                    i += 1
                } else {
                    flush()
                    newPipeline()
                    i += 1
                }
            case "|":
                if current.last == ">" {
                    current.append(ch)
                    i += 1
                } else if next == "|" {
                    flush()
                    newPipeline()
                    i += 2
                } else {
                    flush()
                    i += next == "&" ? 2 : 1
                }
            default:
                current.append(ch)
                i += 1
            }
        }
        flush()
    }

    // MARK: Heredocs

    /// The line in the pieces that run, in order, without the text of its heredocs:
    /// `cat > run.sh <<'EOF' … EOF` writes words, it doesn't run them. A heredoc a shell (or ssh)
    /// reads is kept as a piece of its own, as is one written to a script the line then runs; one
    /// whose end Kore can't find keeps everything after it.
    static func documents(_ command: String) -> [String] {
        guard command.contains("<<") else { return [command] }
        let lines = command.components(separatedBy: "\n")
        var documents: [String] = []
        var main: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            main.append(line)
            index += 1
            let opened = heredocs(in: line)
            guard !opened.isEmpty else { continue }
            var bodies: [String] = []
            var cursor = index
            var closed = true
            for end in opened {
                var body: [String] = []
                while cursor < lines.count, !isEnd(lines[cursor], end) {
                    body.append(lines[cursor])
                    cursor += 1
                }
                guard cursor < lines.count else { closed = false; break }
                cursor += 1
                bodies.append(body.joined(separator: "\n"))
            }
            // No end found: the lines after go on as commands.
            guard closed else { continue }
            if runsHeredoc(line) || runsLater(writtenBy: line, later: lines[cursor...].joined(separator: "\n")) {
                documents.append(main.joined(separator: "\n"))
                main = []
                documents += bodies
            }
            index = cursor
        }
        documents.append(main.joined(separator: "\n"))
        return documents.filter { $0.contains { !$0.isWhitespace } }
    }

    static func isEnd(_ line: String, _ end: (word: String, tabs: Bool)) -> Bool {
        let text = end.tabs ? String(line.drop { $0 == "\t" }) : line
        return text.trimmingCharacters(in: .whitespaces) == end.word
    }

    /// Programs that run a heredoc fed to them.
    static let heredocRunners: Set<String> = shells.union(["ssh", "eval", "source", ".", "sudo", "doas", "su"])

    /// Anything on the line runs what it reads: `bash <<EOF`, `cat <<EOF | sh`, `xargs -0 sh`.
    static func runsHeredoc(_ line: String) -> Bool {
        var out: [Part] = []
        var counter = 0
        scanned(line, into: &out, counter: &counter)
        return out.contains { simple($0.text).map { heredocRunners.contains($0.program) } ?? false }
    }

    /// The line writes its heredoc to a file (`cat > f <<EOF`, `tee f <<EOF`) that `later` runs:
    /// `bash f`, `sh /tmp/f`, `./f`, `source f`.
    static func runsLater(writtenBy line: String, later: String) -> Bool {
        let w = words(line)
        var targets: [String] = []
        for (index, word) in w.enumerated() {
            if [">", ">>", "1>", ">|"].contains(word), index + 1 < w.count {
                targets.append(w[index + 1])
            } else if word.hasPrefix(">"), !word.hasPrefix(">&") {
                targets.append(String(word.drop { $0 == ">" || $0 == "|" }))
            }
        }
        if let tee = simple(line), tee.program == "tee" { targets += tee.arguments.filter { !$0.hasPrefix("-") && !$0.hasPrefix("<") } }
        let names = Set(targets.map(basename).filter { !$0.isEmpty })
        guard !names.isEmpty else { return false }
        let scripts = shells.union(["source", "."])
        return parts(later).contains { part in
            guard let c = simple(part.text) else { return false }
            if c.path.contains("/"), names.contains(c.program) { return true }
            guard scripts.contains(c.program), let file = c.arguments.first(where: { !$0.hasPrefix("-") }) else { return false }
            return names.contains(basename(file))
        }
    }

    /// The end words of the heredocs a line opens (`<<EOF`, `<<-'END'`, `<< "X"`), in order;
    /// `<<<` (a here-string) opens none, nor `<<` in quotes or arithmetic (`$((1<<4))`).
    package static func heredocs(in line: String) -> [(word: String, tabs: Bool)] {
        var found: [(String, Bool)] = []
        let c = Array(line)
        var i = 0
        var quote: Character?
        while i < c.count {
            let ch = c[i]
            if let open = quote {
                if ch == "\\" && open == "\"" { i += 2; continue }
                if ch == open { quote = nil }
                i += 1
                continue
            }
            if ch == "\\" { i += 2; continue }
            if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
            if ch == "#", i == 0 || c[i - 1].isWhitespace || ";|&(".contains(c[i - 1]) { break }
            if ch == "(", i + 1 < c.count, c[i + 1] == "(" {
                var level = 0
                while i < c.count {
                    if c[i] == "(" {
                        level += 1
                    } else if c[i] == ")" {
                        level -= 1
                        if level == 0 { break }
                    }
                    i += 1
                }
                i += 1
                continue
            }
            guard ch == "<", i + 1 < c.count, c[i + 1] == "<" else { i += 1; continue }
            var j = i + 2
            if j < c.count, c[j] == "<" {
                i = j + 1
                continue
            }
            let tabs = j < c.count && c[j] == "-"
            if tabs { j += 1 }
            while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
            var word = ""
            var inner: Character?
            while j < c.count {
                let d = c[j]
                if let open = inner {
                    if d == open { inner = nil } else { word.append(d) }
                } else if d == "'" || d == "\"" {
                    inner = d
                } else if d == "\\" {
                    if j + 1 < c.count { word.append(c[j + 1]) }
                    j += 1
                } else if d.isWhitespace || ";|&<>()".contains(d) {
                    break
                } else {
                    word.append(d)
                }
                j += 1
            }
            if !word.isEmpty { found.append((word, tabs)) }
            i = j
        }
        return found
    }

    // MARK: Variables

    /// The variables a simple command sets for what follows: `T=/tmp/x`, `export OUT="$TMPDIR/o"`,
    /// `tmp=$(mktemp -d)` (a temp path). A value Kore can't read for sure (another command
    /// substitution, an unknown variable, a stray quote) forgets the name, so a path that uses
    /// it still asks.
    static func assign(_ segment: String, into known: inout [String: String]) {
        // Split at blanks outside quotes and substitutions, quotes kept: `G="$HOME/App Support/x"`
        // and `T=$(mktemp -d)` are one token each.
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        var tick = false
        var previous: Character?
        for character in segment {
            if quote == "'" {
                if character == "'" { quote = nil }
                current.append(character)
            } else if character == "`" {
                tick.toggle()
                current.append(character)
            } else if character == "(", previous == "$" {
                depth += 1
                current.append(character)
            } else if character == ")", depth > 0 {
                depth -= 1
                current.append(character)
            } else if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == " " || character == "\t", depth == 0, !tick {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { tokens.append(current) }
        while let first = tokens.first, keywords.contains(first) || ["export", "local", "declare", "typeset", "readonly"].contains(first) {
            tokens.removeFirst()
        }
        for token in tokens {
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { break }
            let name = String(token[..<equals])
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !(name.first?.isNumber ?? true) else { break }
            let raw = String(token[token.index(after: equals)...])
            if let temp = temporary(raw, known) {
                known[name] = temp
                continue
            }
            let quotes = raw.filter { $0 == "\"" }.count, singles = raw.filter { $0 == "'" }.count
            guard quotes % 2 == 0, singles % 2 == 0 else { known[name] = nil; continue }
            var value = raw.filter { $0 != "\"" }
            if raw.hasPrefix("'") { value = raw.filter { $0 != "'" }; known[name] = value; continue }
            value = value.filter { $0 != "'" }
            if value == "~" || value.hasPrefix("~/"), let home = known["HOME"] { value = home + value.dropFirst() }
            known[name] = expand(value, known)
        }
    }

    /// The path `$(mktemp …)` (or `` `mktemp …` ``) makes, when it is in a temp folder: TMPDIR,
    /// /tmp, or a template under them. Nil for any other value.
    static func temporary(_ raw: String, _ known: [String: String]) -> String? {
        var value = raw
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count > 1 { value = String(value.dropFirst().dropLast()) }
        let inner: Substring
        if value.hasPrefix("$("), value.hasSuffix(")") {
            inner = value.dropFirst(2).dropLast()
        } else if value.hasPrefix("`"), value.hasSuffix("`"), value.count > 1 {
            inner = value.dropFirst().dropLast()
        } else {
            return nil
        }
        guard !inner.contains("$("), !inner.contains("`"), !inner.contains(";"), !inner.contains("|"), !inner.contains("&"),
            let c = simple(String(inner)), c.program == "mktemp", !c.sudo
        else { return nil }
        let tmp = known["TMPDIR"] ?? "/tmp"
        var folder: String?
        var template: String?
        var rest = c.arguments[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-p" || argument == "--tmpdir" {
                folder = rest.first
                rest = rest.dropFirst()
            } else if argument.hasPrefix("--tmpdir=") {
                folder = String(argument.dropFirst("--tmpdir=".count))
            } else if argument == "-t" {
                // A prefix (macOS) or a name (GNU): either way in the temp folder.
                if let name = rest.first, !name.hasPrefix("-") {
                    template = basename(name)
                    rest = rest.dropFirst()
                }
            } else if !argument.hasPrefix("-") {
                template = argument
            }
        }
        var path = (folder ?? tmp) + "/" + (template ?? "tmp.kore")
        if let template, template.contains("/") { path = template }
        if path.hasPrefix("~/"), let home = known["HOME"] { path = home + path.dropFirst() }
        guard let expanded = expand(path, known), expanded.hasPrefix("/") else { return nil }
        let made = normalized(expanded)
        let temps = [normalized(tmp), "/tmp", "/private/tmp", "/var/tmp", "/private/var/folders", "/var/folders"].filter { $0 != "/" }
        return temps.contains { made.hasPrefix($0 + "/") } ? made : nil
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

    // MARK: Removals

    /// The Keychain's command-line tool (a word Kore matches, never runs).
    static let keychainTool = "security"
    static let keychainReads: Set<String> = ["find-generic-password", "find-internet-password", "dump-keychain", "export", "find-certificate"]

    static let systemRoots = [
        "/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Users", "/Volumes",
        "/home", "/root", "/boot", "/lib", "/lib64", "/srv", "/mnt", "/media", "/sys", "/proc", "/dev", "/run",
    ]

    /// rm's flags and targets (everything after `--` a target).
    static func removalArguments(_ arguments: [String]) -> (flags: [String], targets: [String]) {
        var flags: [String] = []
        var targets: [String] = []
        var ended = false
        for argument in arguments {
            if !ended, argument == "--" {
                ended = true
            } else if !ended, argument.hasPrefix("-"), argument.count > 1 {
                flags.append(argument)
            } else {
                targets.append(argument)
            }
        }
        return (flags, targets)
    }

    /// -r, -R or -f, or a GNU long option for them (`--recursive`, `--rec`, `--force`, `--forc`).
    static func forced(_ flags: [String]) -> Bool {
        flags.contains { flag in
            if flag.hasPrefix("--") {
                let name = flag.dropFirst(2)
                return !name.isEmpty && ("recursive".hasPrefix(name) || "force".hasPrefix(name))
            }
            return flag.dropFirst().contains { "rRf".contains($0) }
        }
    }

    /// `find`'s starting paths; whether it removes what it finds (`-delete`, `-exec rm`); whether
    /// a test picks what goes (`-name x`), so the folder itself stays; whether it runs sudo.
    static func findRemoval(_ arguments: [String]) -> (paths: [String], removes: Bool, filtered: Bool, sudo: Bool) {
        var rest = arguments[...]
        while let option = rest.first, ["-H", "-L", "-P", "-E", "-X", "-d", "-s", "-x"].contains(option) { rest = rest.dropFirst() }
        if rest.first == "-f" { rest = rest.dropFirst() }
        let paths = Array(rest.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" })
        var expression = Array(rest.dropFirst(paths.count))[...]
        var removes = false
        var filtered = false
        var sudo = false
        let actions: Set<String> = ["-depth", "-print", "-print0", "-xdev", "-mount", "-follow", "-ls", "-mindepth", "-maxdepth", "-d"]
        while let word = expression.first {
            expression = expression.dropFirst()
            if word == "-delete" {
                removes = true
            } else if ["-exec", "-execdir", "-ok", "-okdir"].contains(word) {
                let run = expression.prefix { $0 != ";" && $0 != "+" }
                expression = expression.dropFirst(run.count + 1)
                guard let c = simple(run.joined(separator: " ")) else { continue }
                if c.sudo { sudo = true }
                if ["rm", "rmdir", "unlink"].contains(c.program) { removes = true }
            } else if word.hasPrefix("-"), !actions.contains(word) {
                filtered = true
            }
        }
        return (paths.isEmpty ? ["."] : paths, removes, filtered, sudo)
    }

    /// Why removing these targets is on the list. Forced (-r, -f): a home or system path, or a
    /// path held in a variable Kore can't read. Any removal: paths Kore can't see (a command's
    /// output, an unknown variable, a glob outside the working folder or a temp folder).
    static func removal(_ targets: [String], forced: Bool, known: [String: String], here: String?) -> String? {
        for written in targets {
            guard let path = resolve(written, known: known, here: here) else {
                return forced ? "a forced removal of a path held in a variable" : unseenReason
            }
            if forced, let why = pathReason(path, home: known["HOME"]) { return why }
            if isGlob(path), !insideHereOrTemp(path, here: here, known: known) { return unseenReason }
        }
        return nil
    }

    static func isGlob(_ path: String) -> Bool { path.contains { "*?[".contains($0) } }

    /// A path within the working folder (a relative one without `..`), or a temp folder.
    static func insideHereOrTemp(_ path: String, here: String?, known: [String: String]) -> Bool {
        if !path.hasPrefix("/") && !path.hasPrefix("~") { return !path.split(separator: "/").contains("..") }
        let folders = [here, known["TMPDIR"].map(normalized), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].compactMap { $0 }
        return folders.contains { $0 != "/" && path.hasPrefix($0 + "/") }
    }

    /// A forced removal's target that no rule ever covers: the working folder or one above it,
    /// everything in it, a home folder or a system path.
    static func criticalTarget(_ written: String, known: [String: String], here: String?, cwd: String?) -> Bool {
        guard !written.isEmpty else { return false }
        if ["~", "~/", "~/*"].contains(written) || written.allSatisfy({ $0 == "." || $0 == "/" || $0 == "*" }) { return true }
        let home = written.replacingOccurrences(of: "${HOME}", with: "$HOME")
        if ["$HOME", "$HOME/", "$HOME/*"].contains(home) { return true }
        guard let path = resolve(written, known: known, here: here) else { return false }
        if pathReason(path, home: known["HOME"]) != nil { return true }
        guard path.hasPrefix("/"), let cwd else { return false }
        let judged = isGlob(basename(path)) ? parent(path) : path
        return judged == "/" || cwd == judged || cwd.hasPrefix(judged + "/")
    }

    /// The path a target names: variables filled in, `~` and `~user` as homes, relative to `here`,
    /// `.` and `..` taken out. Nil when a variable can't be read. Without `here`, a relative path
    /// stays as written.
    static func resolve(_ written: String, known: [String: String], here: String?) -> String? {
        var path = written
        if path.contains("$") || path.contains("`") {
            guard let expanded = expand(path, known), !expanded.contains("$") else { return nil }
            path = expanded
        }
        if path.hasPrefix("~") {
            let name = path.dropFirst().prefix { $0 != "/" }
            let rest = path.dropFirst(1 + name.count)
            if name.isEmpty {
                guard let home = known["HOME"] else { return path }
                path = home + rest
            } else if name == "root" {
                path = "/root" + rest
            } else {
                let folder = known["HOME"].map { parent(normalized($0)) }.flatMap { $0 == "/" ? nil : $0 }
                #if os(Linux)
                    path = (folder ?? "/home") + "/" + name + rest
                #else
                    path = (folder ?? "/Users") + "/" + name + rest
                #endif
            }
        }
        if !path.hasPrefix("/"), let here { path = here + "/" + path }
        return normalized(path)
    }

    /// An absolute path with `.`, `..` and repeated slashes taken out (text only, no links); a
    /// relative one as it is.
    static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// Why a forced removal of this path is on the list: a home folder or a folder at its top,
    /// or a system path. A glob at the end (`dir/*`) empties its folder: judged as that folder.
    static func pathReason(_ written: String, home: String?) -> String? {
        var path = written.count > 1 && written.hasSuffix("/") ? String(written.dropLast()) : written
        if isGlob(basename(path)) { path = parent(path) }
        if path.hasPrefix("~") {
            return path == "~" || path.split(separator: "/").count <= 2 ? "a forced removal in your home folder" : nil
        }
        guard path.hasPrefix("/") else { return nil }
        let depth = path.split(separator: "/").count
        if let home = home.map(normalized), home != "/", path == home || path.hasPrefix(home + "/") {
            return depth - home.split(separator: "/").count <= 1 ? "a forced removal in your home folder" : nil
        }
        if ["/Users/", "/home/"].contains(where: path.hasPrefix) {
            if depth <= 2 { return "a forced removal of a home folder" }
            if depth == 3 { return "a forced removal in a home folder" }
        }
        if systemRoots.contains(path) { return "a forced removal of a system path" }
        if systemRoots.dropFirst().contains(where: { path.hasPrefix($0 + "/") }) && depth <= 2 { return "a forced removal of a system path" }
        return nil
    }

    // MARK: Downloads

    /// curl or wget whose output goes into a shell: `curl … | sh`, `curl … | tee f | sh`,
    /// `bash <(curl …)`, `source <(curl …)`, `sh -c "$(curl …)"`, `eval "$(curl …)"`.
    static func pipesDownloadToShell(_ command: String) -> Bool {
        let downloads: Set<String> = ["curl", "wget"]
        let all = parts(command)
        var pipelines: [Int: [String]] = [:]
        var order: [Int] = []
        for part in all {
            if pipelines[part.pipeline] == nil { order.append(part.pipeline) }
            pipelines[part.pipeline, default: []].append(simple(part.text)?.program ?? "")
        }
        for id in order {
            let programs = pipelines[id] ?? []
            if let first = programs.firstIndex(where: downloads.contains), programs[(first + 1)...].contains(where: shells.contains) { return true }
        }
        let runners = shells.union(["source", ".", "eval"])
        for part in all where part.text.contains("(") || part.text.contains("`") {
            guard let c = simple(part.text), runners.contains(c.program) else { continue }
            var inner: [Part] = []
            var counter = 0
            scanned(part.text, into: &inner, counter: &counter)
            if inner.contains(where: { simple($0.text).map { downloads.contains($0.program) } ?? false }) { return true }
        }
        return false
    }
}
