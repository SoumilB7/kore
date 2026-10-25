import Foundation

/// A shell command laid out to be read, never to be run: long chains break at their top-level
/// `&&`, `||`, `|` and `;` onto indented lines, `then`/`do` bodies get their own lines, and each
/// run of text says what it is so a terminal can colour it. Quotes, `$(…)`, `${…}`, backticks,
/// `(…)` groups, `case` and heredoc bodies are never split; a heredoc's body is kept verbatim.
public enum ShellPretty {
    public enum Kind: Sendable, Equatable { case plain, command, keyword, flag, string, variable, op, comment }

    public struct Piece: Sendable, Equatable {
        public let text: String
        public let kind: Kind
        public init(_ text: String, _ kind: Kind) { self.text = text; self.kind = kind }
    }

    /// A command this short, on one line, stays as typed.
    public static let flatWidth = 72
    /// Continuation and body indent, in columns.
    static let indent = "  "

    /// The command as lines of pieces; joining every line's text gives a display, not a script.
    public static func lines(_ command: String, width: Int = flatWidth) -> [[Piece]] {
        var lexer = Lexer(command)
        let tokens = lexer.tokens()
        let breaks: Set<Role> = [.newline, .heredoc, .escapedNewline]
        let written = tokens.contains { breaks.contains($0.role) || $0.text.contains("\n") }
        let length = tokens.reduce(0) { sum, token in sum + (token.role == .space ? 1 : token.text.count) }
        if !written, length <= width { return [Layout.flat(tokens)] }
        var layout = Layout(tokens)
        return layout.laidOut()
    }

    /// The lines as plain text, for tests and logs.
    public static func text(_ command: String, width: Int = flatWidth) -> [String] {
        lines(command, width: width).map { $0.map(\.text).joined() }
    }

    // MARK: - Tokens

    enum Role: Equatable {
        case word, space, separator, chain, pipe, newline, escapedNewline, heredoc
        /// `then`, `do`: a body follows. `else`: one ends and another starts. `elif`: one ends.
        case open, middle, elif, close
    }

    struct Token {
        let text: String
        let kind: Kind
        let role: Role
    }

    private struct Lexer {
        let chars: [Character]
        var at = 0
        var out: [Token] = []
        var commandPosition = true
        /// `(…)` subshells and `case … esac`: chains inside stay on their line.
        var group = 0
        var cases = 0
        var pendingHeredocs: [(delimiter: String, tabs: Bool)] = []

        init(_ text: String) { chars = Array(text) }

        mutating func tokens() -> [Token] {
            while at < chars.count { step() }
            return out
        }

        private var top: Bool { group == 0 && cases == 0 }

        private mutating func emit(_ text: String, _ kind: Kind, _ role: Role = .word) {
            out.append(Token(text: text, kind: kind, role: role))
        }

        private mutating func step() {
            let c = chars[at]
            if c == "\n" {
                at += 1
                emit("\n", .plain, top ? .newline : .space)
                commandPosition = true
                readHeredocBodies()
                return
            }
            if c == " " || c == "\t" {
                while at < chars.count, chars[at] == " " || chars[at] == "\t" { at += 1 }
                emit(" ", .plain, .space)
                return
            }
            if c == "\\", peek(1) == "\n" {
                at += 2
                emit("\\", .plain, top ? .escapedNewline : .space)
                return
            }
            if c == "#" { comment(); return }
            if operatorToken() { return }
            word()
        }

        private func peek(_ offset: Int) -> Character? {
            at + offset < chars.count ? chars[at + offset] : nil
        }

        private func starts(_ text: String) -> Bool {
            var i = at
            for ch in text {
                guard i < chars.count, chars[i] == ch else { return false }
                i += 1
            }
            return true
        }

        private mutating func comment() {
            let start = at
            while at < chars.count, chars[at] != "\n" { at += 1 }
            emit(String(chars[start..<at]), .comment)
        }

        /// Separators, chains, pipes, groups and redirections; false when a word starts here.
        private mutating func operatorToken() -> Bool {
            for (text, role) in [("&&", Role.chain), ("||", .chain), (";;", .separator), ("|&", .pipe)] where starts(text) {
                at += 2
                emit(text, .op, top ? role : .word)
                if text == ";;" { commandPosition = false } else { commandPosition = true }
                return true
            }
            let c = chars[at]
            if c == "&", peek(1) == ">" { redirection(); return true }
            if c == ";" || c == "&" || c == "|" {
                at += 1
                emit(String(c), .op, top ? (c == "|" ? .pipe : .separator) : .word)
                commandPosition = cases == 0 || c != "|"
                return true
            }
            if c == "(" && commandPosition {
                at += 1
                group += 1
                emit("(", .op)
                return true
            }
            if c == ")" {
                at += 1
                if cases == 0 { group = max(0, group - 1) }
                emit(")", .op)
                commandPosition = cases > 0
                return true
            }
            if c == "<" || c == ">" {
                if peek(1) == "(" { substitution(); return true }
                redirection()
                return true
            }
            return false
        }

        private mutating func redirection() {
            let start = at
            if chars[at] == "&" { at += 1 }
            let first = chars[at]
            at += 1
            var heredoc = false, tabs = false
            if first == "<", at < chars.count, chars[at] == "<" {
                at += 1
                if at < chars.count, chars[at] == "<" { at += 1 } else {
                    heredoc = true
                    if at < chars.count, chars[at] == "-" { at += 1; tabs = true }
                }
            } else if at < chars.count, chars[at] == first || chars[at] == "&" || chars[at] == "|" {
                at += 1
            }
            if !heredoc, at < chars.count, chars[at] == "-" || chars[at].isNumber, chars[at - 1] == "&" {
                while at < chars.count, chars[at] == "-" || chars[at].isNumber { at += 1 }
            }
            emit(String(chars[start..<at]), .op)
            guard heredoc else { return }
            while at < chars.count, chars[at] == " " { at += 1 }
            let begin = at
            var delimiter = ""
            while at < chars.count, !" \t\n;&|<>()".contains(chars[at]) {
                if chars[at] == "'" || chars[at] == "\"" {
                    let quote = chars[at]
                    at += 1
                    while at < chars.count, chars[at] != quote { delimiter.append(chars[at]); at += 1 }
                    if at < chars.count { at += 1 }
                } else {
                    if chars[at] != "\\" { delimiter.append(chars[at]) }
                    at += 1
                }
            }
            if at > begin { emit(String(chars[begin..<at]), .string) }
            if !delimiter.isEmpty { pendingHeredocs.append((delimiter, tabs)) }
        }

        /// After a newline: the bodies of the heredocs its line opened, verbatim.
        private mutating func readHeredocBodies() {
            while !pendingHeredocs.isEmpty {
                let (delimiter, tabs) = pendingHeredocs.removeFirst()
                var body: [String] = []
                while at < chars.count {
                    let start = at
                    while at < chars.count, chars[at] != "\n" { at += 1 }
                    let line = String(chars[start..<at])
                    if at < chars.count { at += 1 }
                    let bare = tabs ? String(line.drop { $0 == "\t" }) : line
                    if bare == delimiter {
                        if !body.isEmpty { emit(body.joined(separator: "\n"), .plain, .heredoc) }
                        emit(line, .string, .heredoc)
                        body = []
                        break
                    }
                    body.append(line)
                }
                if !body.isEmpty { emit(body.joined(separator: "\n"), .plain, .heredoc) }
            }
        }

        /// One shell word, as pieces: quoted and substituted parts coloured on their own.
        private mutating func word() {
            let first = out.count
            var bare = ""
            var kind: Kind?
            while at < chars.count {
                let c = chars[at]
                if " \t\n;&|<>".contains(c) || (c == ")" && (group > 0 || cases > 0)) { break }
                switch c {
                case "\\":
                    bare.append(c)
                    at += 1
                    if at < chars.count { bare.append(chars[at]); at += 1 }
                case "'":
                    flush(&bare, first: first, kind: &kind)
                    let start = at
                    at += 1
                    while at < chars.count, chars[at] != "'" { at += 1 }
                    at = min(at + 1, chars.count)
                    emit(String(chars[start..<at]), .string)
                case "\"":
                    flush(&bare, first: first, kind: &kind)
                    doubleQuoted()
                case "$" where peek(1) == "'":
                    flush(&bare, first: first, kind: &kind)
                    let start = at
                    at += 2
                    while at < chars.count, chars[at] != "'" { at += chars[at] == "\\" ? 2 : 1 }
                    at = min(at + 1, chars.count)
                    emit(String(chars[start..<at]), .string)
                case "$", "`":
                    flush(&bare, first: first, kind: &kind)
                    substitution()
                default:
                    bare.append(c)
                    at += 1
                }
            }
            flush(&bare, first: first, kind: &kind)
            guard out.count > first else {
                // A character the loop declined: take it so the lexer always moves on.
                at += 1
                emit(String(chars[at - 1]), .op)
                return
            }
            let head = out[first]
            if out.count == first + 1, head.text.allSatisfy(\.isNumber), at < chars.count, chars[at] == ">" || chars[at] == "<" {
                // `2>&1`: the descriptor reads as part of its redirection.
                out[first] = Token(text: head.text, kind: .op, role: .word)
                return
            }
            if out.count == first + 1, head.kind == .keyword || (cases > 0 && head.text == "esac") {
                if head.text == "case" { cases += 1 }
                if head.text == "esac" { cases = max(0, cases - 1) }
                out[first] = Token(text: head.text, kind: .keyword, role: Self.layoutRole(head.text, top: top))
                commandPosition = !["done", "fi", "esac", "}", "case", "for", "select", "function"].contains(head.text)
                return
            }
            // `NAME=value cmd`: the command still follows.
            if commandPosition, head.kind == .variable, head.text.contains("=") { return }
            commandPosition = false
        }

        /// The unquoted text gathered so far: the word's first part says what the word is.
        private mutating func flush(_ bare: inout String, first: Int, kind: inout Kind?) {
            guard !bare.isEmpty else { return }
            let isFirst = out.count == first
            let piece: Kind
            if isFirst, commandPosition {
                piece = Self.keywords.contains(bare) ? .keyword : bare.contains("=") && !bare.hasPrefix("=") ? .variable : .command
            } else if isFirst {
                piece = bare.hasPrefix("-") && bare.count > 1 ? .flag : .plain
            } else {
                piece = kind ?? .plain
            }
            kind = piece == .keyword || piece == .variable ? .plain : piece
            emit(bare, piece)
            bare = ""
        }

        private static let keywords: Set<String> = [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
            "select", "function", "time", "!", "{", "}", "in",
        ]

        private static func layoutRole(_ word: String, top: Bool) -> Role {
            guard top else { return .word }
            switch word {
            case "then", "do": return .open
            case "else": return .middle
            case "elif": return .elif
            case "fi", "done": return .close
            default: return .word
            }
        }

        /// `"…"`: string text, with its `$…` and backtick parts as variables.
        private mutating func doubleQuoted() {
            var text = "\""
            at += 1
            while at < chars.count, chars[at] != "\"" {
                let c = chars[at]
                if c == "\\" {
                    text.append(c)
                    at += 1
                    if at < chars.count { text.append(chars[at]); at += 1 }
                } else if c == "`" || (c == "$" && at + 1 < chars.count && (chars[at + 1] == "(" || chars[at + 1] == "{" || Self.nameStart(chars[at + 1]))) {
                    emit(text, .string)
                    text = ""
                    substitution()
                } else {
                    text.append(c)
                    at += 1
                }
            }
            if at < chars.count { text.append("\""); at += 1 }
            if !text.isEmpty { emit(text, .string) }
        }

        private static func nameStart(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || "@*#?$!-".contains(c)
        }

        /// `$name`, `${…}`, `$(…)`, `$((…))`, `` `…` ``, `<(…)`, `>(…)`: one variable piece.
        private mutating func substitution() {
            let start = at
            if chars[at] == "`" {
                at += 1
                while at < chars.count, chars[at] != "`" { at += chars[at] == "\\" ? 2 : 1 }
                at = min(at + 1, chars.count)
            } else if peek(1) == "(" {
                at += 2
                skip(until: ")")
            } else if peek(1) == "{" {
                at += 2
                skip(until: "}")
            } else {
                at += 1
                if at < chars.count, chars[at].isLetter || chars[at] == "_" {
                    while at < chars.count, chars[at].isLetter || chars[at].isNumber || chars[at] == "_" { at += 1 }
                } else if at < chars.count, Self.nameStart(chars[at]) {
                    at += 1
                }
            }
            at = min(at, chars.count)
            emit(String(chars[start..<at]), .variable)
        }

        /// Past the `close` that ends what an opener began, honouring quotes, nesting, escapes
        /// and heredoc bodies inside (`$(cat <<'EOF' … EOF)`).
        private mutating func skip(until close: Character) {
            var depth = 0
            var heredocs: [(String, Bool)] = []
            var wordStart = true
            while at < chars.count {
                let c = chars[at]
                switch c {
                case "\\": at += 2; wordStart = false; continue
                case "'":
                    at += 1
                    while at < chars.count, chars[at] != "'" { at += 1 }
                case "\"":
                    at += 1
                    while at < chars.count, chars[at] != "\"" {
                        if chars[at] == "\\" { at += 2; continue }
                        if chars[at] == "$", peek(1) == "(" || peek(1) == "{" {
                            let inner: Character = peek(1) == "(" ? ")" : "}"
                            at += 2
                            skip(until: inner)
                            continue
                        }
                        if chars[at] == "`" {
                            at += 1
                            while at < chars.count, chars[at] != "`" { at += chars[at] == "\\" ? 2 : 1 }
                        }
                        at += 1
                    }
                case "`":
                    at += 1
                    while at < chars.count, chars[at] != "`" { at += chars[at] == "\\" ? 2 : 1 }
                case "$" where peek(1) == "(" || peek(1) == "{":
                    let inner: Character = peek(1) == "(" ? ")" : "}"
                    at += 2
                    skip(until: inner)
                    wordStart = false
                    continue
                case "#" where wordStart && close == ")":
                    while at < chars.count, chars[at] != "\n" { at += 1 }
                    continue
                case "<" where close == ")" && starts("<<") && !starts("<<<"):
                    at += 2
                    var tabs = false
                    if at < chars.count, chars[at] == "-" { at += 1; tabs = true }
                    while at < chars.count, chars[at] == " " { at += 1 }
                    var delimiter = ""
                    while at < chars.count, !" \t\n;&|<>()".contains(chars[at]) {
                        if chars[at] != "'" && chars[at] != "\"" && chars[at] != "\\" { delimiter.append(chars[at]) }
                        at += 1
                    }
                    if !delimiter.isEmpty { heredocs.append((delimiter, tabs)) }
                    wordStart = false
                    continue
                case "\n":
                    at += 1
                    for (delimiter, tabs) in heredocs {
                        while at < chars.count {
                            let begin = at
                            while at < chars.count, chars[at] != "\n" { at += 1 }
                            let line = String(chars[begin..<at])
                            if at < chars.count { at += 1 }
                            if (tabs ? String(line.drop { $0 == "\t" }) : line) == delimiter { break }
                        }
                    }
                    heredocs = []
                    wordStart = true
                    continue
                case "(" where close == ")": depth += 1
                case "{" where close == "}": depth += 1
                case close:
                    if depth == 0 { at += 1; return }
                    depth -= 1
                default: break
                }
                wordStart = " \t;&|(".contains(c)
                at += 1
            }
        }
    }

    // MARK: - Layout

    private struct Layout {
        let tokens: [Token]
        var lines: [[Piece]] = []
        var line: [Piece] = []
        var depth = 0
        /// The current line continues a command: it starts with `&&`, `|`, or follows a `\`.
        var continued = false

        init(_ tokens: [Token]) { self.tokens = tokens }

        static func flat(_ tokens: [Token]) -> [Piece] {
            var line: [Piece] = []
            for token in tokens {
                if token.role == .space { if !line.isEmpty, line.last?.text != " " { line.append(Piece(" ", .plain)) } } else {
                    line.append(Piece(token.text, token.kind))
                }
            }
            while line.last?.text == " " { line.removeLast() }
            return line
        }

        private var lineIsEmpty: Bool { !line.contains { $0.text != " " } }

        private mutating func append(_ token: Token) {
            if lineIsEmpty {
                line = [Piece(String(repeating: ShellPretty.indent, count: depth + (continued ? 1 : 0)), .plain)]
            }
            line.append(Piece(token.text, token.kind))
        }

        private mutating func space() {
            guard !lineIsEmpty, line.last?.text != " " else { return }
            line.append(Piece(" ", .plain))
        }

        private mutating func newLine(continued: Bool = false) {
            while line.last?.text == " " { line.removeLast() }
            if !lineIsEmpty { lines.append(line) }
            line = []
            self.continued = continued
        }

        /// The next token that isn't a space.
        private func next(after index: Int) -> Token? {
            tokens[(index + 1)...].first { $0.role != .space }
        }

        mutating func laidOut() -> [[Piece]] {
            for (index, token) in tokens.enumerated() {
                switch token.role {
                case .space: space()
                case .word: append(token)
                case .chain, .pipe:
                    newLine(continued: true)
                    append(token)
                    space()
                case .separator:
                    // `; then`, `; do` stay on their line; elsewhere a line break says what `;` did.
                    if let next = next(after: index), next.role == .open {
                        append(token)
                    } else {
                        if token.text != ";" { append(token) }
                        newLine()
                    }
                case .newline: newLine()
                case .escapedNewline:
                    space()
                    append(token)
                    newLine(continued: true)
                case .heredoc:
                    newLine()
                    lines.append([Piece(token.text, token.kind)])
                case .open:
                    append(token)
                    depth += 1
                    newLine()
                case .middle:
                    newLine()
                    depth = max(0, depth - 1)
                    append(token)
                    depth += 1
                    newLine()
                case .elif:
                    newLine()
                    depth = max(0, depth - 1)
                    append(token)
                case .close:
                    newLine()
                    depth = max(0, depth - 1)
                    append(token)
                }
            }
            newLine()
            return lines.flatMap { line -> [[Piece]] in
                // A heredoc body joined with newlines comes back as one line per line.
                guard line.count == 1, line[0].text.contains("\n") else { return [line] }
                return line[0].text.components(separatedBy: "\n").map { [Piece($0, line[0].kind)] }
            }
        }
    }
}
