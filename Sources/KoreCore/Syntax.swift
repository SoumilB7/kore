import Foundation

/// What a run of source text is, for colouring.
public enum TokenKind: UInt8, Sendable, CaseIterable {
    case keyword, string, number, comment, type, function, property, attribute, constant
    case heading, link, emphasis, code, tag, punctuation
}

/// A language as the editor colours it: a small scanner per family (code, markdown, markup,
/// data), configured by keywords and comment and quote styles. Line by line, so the editor
/// can colour only what's on screen: each line starts from the state the previous one ended
/// in (inside a block comment, a multi-line string, a code fence, a tag).
public struct Language: Sendable, Equatable {
    public enum Family: Sendable { case code, markdown, markup, plain }

    public let id: String
    public let name: String
    public let family: Family
    let lineComments: [[UInt16]]
    let block: (open: [UInt16], close: [UInt16])?
    let keywords: Set<String>
    let constants: Set<String>
    let quotes: Set<UInt16>
    /// Quotes that may span lines (template literals, triple quotes).
    let multilineQuotes: Set<UInt16>
    let tripleQuotes: Bool
    let caseInsensitive: Bool
    /// `#if`, `#include`: a `#` word at the start of a line is a keyword.
    let hashDirectives: Bool
    /// `@decorator`, `@MainActor`, `@media`.
    let atWords: Bool
    /// `$name`, `${name}`, `$(name)`.
    let dollarWords: Bool
    /// A name (or quoted name) followed by `:` or `=` is a key (JSON, YAML, CSS, TOML).
    let keys: Bool

    public static func == (a: Language, b: Language) -> Bool { a.id == b.id }

    /// The line comment to toggle with ⌘/, if the language has one.
    public var commentPrefix: String? {
        if let first = lineComments.first { return String(utf16CodeUnits: first, count: first.count) }
        return nil
    }

    /// Block comment delimiters, for languages without a line comment (HTML, CSS).
    public var blockComment: (String, String)? {
        block.map { (String(utf16CodeUnits: $0.open, count: $0.open.count), String(utf16CodeUnits: $0.close, count: $0.close.count)) }
    }

    init(
        _ id: String, _ name: String, family: Family = .code, line: [String] = [], block: (String, String)? = nil,
        keywords: String = "", constants: String = "", quotes: String = "\"'", multiline: String = "",
        triple: Bool = false, caseInsensitive: Bool = false, hash: Bool = false, at: Bool = false,
        dollar: Bool = false, keys: Bool = false
    ) {
        self.id = id
        self.name = name
        self.family = family
        lineComments = line.map { Array($0.utf16) }
        self.block = block.map { (Array($0.0.utf16), Array($0.1.utf16)) }
        let words = keywords.split(separator: " ").map { caseInsensitive ? $0.lowercased() : String($0) }
        self.keywords = Set(words)
        self.constants = Set(constants.split(separator: " ").map(String.init))
        self.quotes = Set(quotes.utf16)
        multilineQuotes = Set(multiline.utf16)
        tripleQuotes = triple
        self.caseInsensitive = caseInsensitive
        hashDirectives = hash
        atWords = at
        dollarWords = dollar
        self.keys = keys
    }
}

// MARK: - Scanning

extension Language {
    /// Where a line starts: inside nothing, or inside something the line before left open.
    public enum State: Equatable, Sendable {
        case normal
        case blockComment
        case string(quote: UInt16, triple: Bool)
        case fence
        case tag
    }

    public struct Token: Equatable, Sendable {
        /// UTF-16 offsets within the line.
        public let range: Range<Int>
        public let kind: TokenKind
    }

    /// The tokens of one line (UTF-16, without its newline) and the state it ends in.
    public func scan(_ line: [UInt16], from start: State, into tokens: inout [Token]) -> State {
        switch family {
        case .plain: start
        case .markdown: scanMarkdown(line, from: start, into: &tokens)
        case .markup: scanMarkup(line, from: start, into: &tokens)
        case .code: scanCode(line, from: start, into: &tokens)
        }
    }

    /// Only the state a line ends in: the cheap pass for lines above the visible ones.
    public func endState(_ line: [UInt16], from start: State) -> State {
        var ignored: [Token] = []
        ignored.reserveCapacity(16)
        return scan(line, from: start, into: &ignored)
    }

    private func scanCode(_ s: [UInt16], from start: State, into tokens: inout [Token]) -> State {
        let n = s.count
        var i = 0
        func emit(_ a: Int, _ b: Int, _ kind: TokenKind) { if b > a { tokens.append(Token(range: a..<b, kind: kind)) } }

        switch start {
        case .blockComment:
            guard let block, let end = find(block.close, in: s, from: 0) else {
                emit(0, n, .comment)
                return .blockComment
            }
            emit(0, end + block.close.count, .comment)
            i = end + block.close.count
        case .string(let quote, let triple):
            let (end, closed) = closeString(s, from: 0, quote: quote, triple: triple)
            emit(0, end, .string)
            if !closed { return start }
            i = end
        default:
            break
        }

        var lineStart = true
        while i < n {
            let c = s[i]
            if c == .space || c == .tab {
                i += 1
                continue
            }
            let first = lineStart
            lineStart = false
            // Comments. A `#` comment starts a word, so `$#` and `a#b` aren't comments.
            if let comment = lineComments.first(where: { starts($0, s, at: i) }),
                comment != [.hash] || i == 0 || s[i - 1] == .space || s[i - 1] == .tab
            {
                emit(i, n, .comment)
                return .normal
            }
            if let block, starts(block.open, s, at: i) {
                guard let end = find(block.close, in: s, from: i + block.open.count) else {
                    emit(i, n, .comment)
                    return .blockComment
                }
                emit(i, end + block.close.count, .comment)
                i = end + block.close.count
                continue
            }
            if hashDirectives, c == .hash, first {
                let end = identEnd(s, from: i + 1)
                emit(i, end, .keyword)
                i = max(end, i + 1)
                continue
            }
            if quotes.contains(c) {
                let triple = tripleQuotes && i + 2 < n && s[i + 1] == c && s[i + 2] == c
                let (end, closed) = closeString(s, from: i + (triple ? 3 : 1), quote: c, triple: triple)
                emit(i, end, keys && isKey(s, after: end) ? .property : .string)
                if !closed {
                    if triple || multilineQuotes.contains(c) { return .string(quote: c, triple: triple) }
                }
                i = end
                continue
            }
            if isDigit(c) || (c == .dot && i + 1 < n && isDigit(s[i + 1]) && (i == 0 || !isIdent(s[i - 1]))) {
                var end = i + 1
                while end < n, isIdent(s[end]) || s[end] == .dot && end + 1 < n && isDigit(s[end + 1]) { end += 1 }
                emit(i, end, .number)
                i = end
                continue
            }
            if atWords, c == .at, i + 1 < n, isIdentStart(s[i + 1]) {
                let end = identEnd(s, from: i + 1)
                emit(i, end, .attribute)
                i = end
                continue
            }
            if dollarWords, c == .dollar, i + 1 < n {
                var end = i + 1
                if s[end] == .braceOpen || s[end] == .parenOpen {
                    let close = s[end] == .braceOpen ? UInt16.braceClose : .parenClose
                    while end < n, s[end] != close { end += 1 }
                    end = min(end + 1, n)
                } else {
                    end = isIdentStart(s[end]) ? identEnd(s, from: end) : end + 1
                }
                emit(i, end, .property)
                i = end
                continue
            }
            if keys, c == .hash, i + 1 < n, isHex(s[i + 1]) {
                // CSS colours.
                let end = identEnd(s, from: i + 1)
                emit(i, end, .number)
                i = end
                continue
            }
            if isIdentStart(c) {
                let end = identEnd(s, from: i)
                if let kind = wordKind(s, i, end) { emit(i, end, kind) }
                i = end
                continue
            }
            if Self.punctuation.contains(c) { emit(i, i + 1, .punctuation) }
            i += 1
        }
        return .normal
    }

    /// Brackets, commas, dots, colons and semicolons.
    private static let punctuation: Set<UInt16> = [
        .parenOpen, .parenClose, .bracketOpen, .bracketClose, .braceOpen, .braceClose, .comma, .dot, .colon, .semicolon,
    ]

    private func wordKind(_ s: [UInt16], _ a: Int, _ b: Int) -> TokenKind? {
        var word = String(utf16CodeUnits: Array(s[a..<b]), count: b - a)
        if caseInsensitive { word = word.lowercased() }
        if keys && isKey(s, after: b) { return .property }
        if keywords.contains(word) {
            // `.default`, `x.type`: a member, not the keyword.
            return a > 0 && s[a - 1] == .dot && !(a > 1 && s[a - 2] == .dot) ? .property : .keyword
        }
        if constants.contains(word) { return .constant }
        if next(s, from: b) == .parenOpen { return .function }
        if a > 0, s[a - 1] == .dot { return .property }
        if s[a] >= 0x41 && s[a] <= 0x5A { return b - a > 1 && isAllCaps(s, a, b) ? .constant : .type }
        return nil
    }

    // MARK: Markdown

    private func scanMarkdown(_ s: [UInt16], from start: State, into tokens: inout [Token]) -> State {
        let n = s.count
        func emit(_ a: Int, _ b: Int, _ kind: TokenKind) { if b > a { tokens.append(Token(range: a..<b, kind: kind)) } }
        var i = 0
        while i < n, s[i] == .space { i += 1 }
        let fence = starts([.backtick, .backtick, .backtick], s, at: i) || starts([.tilde, .tilde, .tilde], s, at: i)
        if start == .fence {
            emit(0, n, .code)
            return fence ? .normal : .fence
        }
        if fence {
            emit(0, n, .code)
            return .fence
        }
        if i < n, s[i] == .hash {
            var level = i
            while level < n, s[level] == .hash { level += 1 }
            if level == n || s[level] == .space {
                emit(0, n, .heading)
                return .normal
            }
        }
        if i < n, s[i] == .greater {
            emit(i, i + 1, .punctuation)
            return .normal
        }
        // List markers.
        if i + 1 < n, s[i] == .dash || s[i] == .star || s[i] == .plus, s[i + 1] == .space {
            emit(i, i + 1, .punctuation)
            i += 2
        } else {
            var digits = i
            while digits < n, isDigit(s[digits]) { digits += 1 }
            if digits > i, digits + 1 < n, s[digits] == .dot, s[digits + 1] == .space {
                emit(i, digits + 1, .punctuation)
                i = digits + 2
            }
        }
        while i < n {
            let c = s[i]
            if c == .backtick, let end = find([.backtick], in: s, from: i + 1) {
                emit(i, end + 1, .code)
                i = end + 1
            } else if c == .bracketOpen, let close = find([.bracketClose], in: s, from: i + 1), close + 1 < n,
                s[close + 1] == .parenOpen, let end = find([.parenClose], in: s, from: close + 2)
            {
                emit(i, end + 1, .link)
                i = end + 1
            } else if (c == .star || c == .underscore), i + 1 < n, s[i + 1] != .space,
                let end = emphasisEnd(s, from: i, mark: c)
            {
                emit(i, end, .emphasis)
                i = end
            } else {
                i += 1
            }
        }
        return .normal
    }

    private func emphasisEnd(_ s: [UInt16], from i: Int, mark: UInt16) -> Int? {
        let double = i + 1 < s.count && s[i + 1] == mark
        let width = double ? 2 : 1
        var j = i + width
        while j < s.count {
            if s[j] == mark, s[j - 1] != .space, !double || (j + 1 < s.count && s[j + 1] == mark) {
                return j + width
            }
            j += 1
        }
        return nil
    }

    // MARK: Markup

    private func scanMarkup(_ s: [UInt16], from start: State, into tokens: inout [Token]) -> State {
        let n = s.count
        func emit(_ a: Int, _ b: Int, _ kind: TokenKind) { if b > a { tokens.append(Token(range: a..<b, kind: kind)) } }
        var i = 0
        var inTag = start == .tag
        let open: [UInt16] = Array("<!--".utf16)
        let close: [UInt16] = Array("-->".utf16)
        if start == .blockComment {
            guard let end = find(close, in: s, from: 0) else {
                emit(0, n, .comment)
                return .blockComment
            }
            emit(0, end + 3, .comment)
            i = end + 3
        }
        if case .string(let quote, _) = start {
            let (end, closed) = closeString(s, from: 0, quote: quote, triple: false)
            emit(0, end, .string)
            if !closed { return start }
            i = end
            inTag = true
        }
        while i < n {
            let c = s[i]
            if !inTag {
                if starts(open, s, at: i) {
                    guard let end = find(close, in: s, from: i + 4) else {
                        emit(i, n, .comment)
                        return .blockComment
                    }
                    emit(i, end + 3, .comment)
                    i = end + 3
                } else if c == .less, i + 1 < n, isIdentStart(s[i + 1]) || s[i + 1] == .slash || s[i + 1] == .bang || s[i + 1] == .question {
                    var end = i + 1
                    while end < n, s[end] == .slash || s[end] == .bang || s[end] == .question { end += 1 }
                    end = identEnd(s, from: end, extra: [.dash, .colon, .dot])
                    emit(i, end, .tag)
                    i = end
                    inTag = true
                } else if c == .amp, let end = find([.semicolon], in: s, from: i + 1), end - i < 10 {
                    emit(i, end + 1, .constant)
                    i = end + 1
                } else {
                    i += 1
                }
                continue
            }
            if c == .greater || (c == .slash && i + 1 < n && s[i + 1] == .greater) || (c == .question && i + 1 < n && s[i + 1] == .greater) {
                let end = c == .greater ? i + 1 : i + 2
                emit(i, end, .tag)
                i = end
                inTag = false
            } else if c == .quote || c == .apostrophe {
                let (end, closed) = closeString(s, from: i + 1, quote: c, triple: false)
                emit(i, end, .string)
                if !closed { return .string(quote: c, triple: false) }
                i = end
            } else if isIdentStart(c) {
                let end = identEnd(s, from: i, extra: [.dash, .colon, .dot])
                emit(i, end, .property)
                i = end
            } else {
                i += 1
            }
        }
        return inTag ? .tag : .normal
    }

    // MARK: Helpers

    private func closeString(_ s: [UInt16], from start: Int, quote: UInt16, triple: Bool) -> (end: Int, closed: Bool) {
        var i = start
        while i < s.count {
            if s[i] == .backslash {
                i += 2
                continue
            }
            if s[i] == quote {
                if !triple { return (i + 1, true) }
                if i + 2 < s.count, s[i + 1] == quote, s[i + 2] == quote { return (i + 3, true) }
            }
            i += 1
        }
        return (s.count, false)
    }

    /// A key: followed by `:` (not `::`) or, for TOML, `=`.
    private func isKey(_ s: [UInt16], after end: Int) -> Bool {
        guard let index = nextIndex(s, from: end) else { return false }
        if s[index] == .colon { return !(index + 1 < s.count && s[index + 1] == .colon) }
        return id == "toml" && s[index] == .equals && !(index + 1 < s.count && s[index + 1] == .equals)
    }

    private func next(_ s: [UInt16], from i: Int) -> UInt16? { nextIndex(s, from: i).map { s[$0] } }

    private func nextIndex(_ s: [UInt16], from i: Int) -> Int? {
        var j = i
        while j < s.count, s[j] == .space || s[j] == .tab { j += 1 }
        return j < s.count ? j : nil
    }

    private func identEnd(_ s: [UInt16], from i: Int, extra: Set<UInt16> = []) -> Int {
        var end = i
        while end < s.count, isIdent(s[end]) || extra.contains(s[end]) {
            end += 1
        }
        return end
    }

    private func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == .underscore || c > 0x7F
            || (c == .dollar && !dollarWords && (id == "javascript" || id == "typescript"))
    }

    private func isIdent(_ c: UInt16) -> Bool {
        isIdentStart(c) || isDigit(c) || (keys && c == .dash && (id == "css" || id == "yaml"))
            || (c == .question && id == "ruby")
    }

    private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }

    private func isAllCaps(_ s: [UInt16], _ a: Int, _ b: Int) -> Bool {
        s[a..<b].allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || $0 == .underscore || isDigit($0) }
    }

    private func starts(_ prefix: [UInt16], _ s: [UInt16], at i: Int) -> Bool {
        guard !prefix.isEmpty, i + prefix.count <= s.count else { return false }
        for k in 0..<prefix.count where s[i + k] != prefix[k] { return false }
        return true
    }

    private func find(_ needle: [UInt16], in s: [UInt16], from i: Int) -> Int? {
        guard !needle.isEmpty, s.count >= needle.count, i <= s.count - needle.count else { return nil }
        for j in i...(s.count - needle.count) where starts(needle, s, at: j) { return j }
        return nil
    }
}

extension UInt16 {
    public static let comma: UInt16 = 0x2C
    public static let tab: UInt16 = 0x09
    public static let space: UInt16 = 0x20
    public static let bang: UInt16 = 0x21
    public static let quote: UInt16 = 0x22
    public static let hash: UInt16 = 0x23
    public static let dollar: UInt16 = 0x24
    public static let amp: UInt16 = 0x26
    public static let apostrophe: UInt16 = 0x27
    public static let parenOpen: UInt16 = 0x28
    public static let parenClose: UInt16 = 0x29
    public static let star: UInt16 = 0x2A
    public static let plus: UInt16 = 0x2B
    public static let dash: UInt16 = 0x2D
    public static let dot: UInt16 = 0x2E
    public static let slash: UInt16 = 0x2F
    public static let colon: UInt16 = 0x3A
    public static let semicolon: UInt16 = 0x3B
    public static let less: UInt16 = 0x3C
    public static let equals: UInt16 = 0x3D
    public static let greater: UInt16 = 0x3E
    public static let question: UInt16 = 0x3F
    public static let at: UInt16 = 0x40
    public static let bracketOpen: UInt16 = 0x5B
    public static let backslash: UInt16 = 0x5C
    public static let bracketClose: UInt16 = 0x5D
    public static let underscore: UInt16 = 0x5F
    public static let backtick: UInt16 = 0x60
    public static let braceOpen: UInt16 = 0x7B
    public static let braceClose: UInt16 = 0x7D
    public static let tilde: UInt16 = 0x7E
}

// MARK: - The languages

extension Language {
    public static let plain = Language("plaintext", "Plain Text", family: .plain)

    static let cKeywords =
        "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool"

    static let swift = Language(
        "swift", "Swift", line: ["//"], block: ("/*", "*/"),
        keywords:
            "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws actor some any nonisolated isolated mutating nonmutating override final lazy weak unowned convenience required indirect consuming borrowing get set willSet didSet self Self super macro package",
        constants: "true false nil", quotes: "\"", triple: true, hash: true, at: true)
    static let javascript = Language(
        "javascript", "JavaScript", line: ["//"], block: ("/*", "*/"),
        keywords:
            "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set from as",
        constants: "true false null undefined NaN Infinity", quotes: "\"'`", multiline: "`", at: true)
    static let typescript = Language(
        "typescript", "TypeScript", line: ["//"], block: ("/*", "*/"),
        keywords: javascript.keywordList
            + " interface type enum implements namespace declare readonly private protected public abstract keyof infer is satisfies",
        constants: "true false null undefined NaN Infinity", quotes: "\"'`", multiline: "`", at: true)
    static let python = Language(
        "python", "Python", line: ["#"],
        keywords:
            "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls",
        constants: "True False None", triple: true, at: true)
    static let go = Language(
        "go", "Go", line: ["//"], block: ("/*", "*/"),
        keywords:
            "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        constants: "true false nil iota", quotes: "\"'`", multiline: "`")
    static let rust = Language(
        "rust", "Rust", line: ["//"], block: ("/*", "*/"),
        keywords:
            "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
        constants: "true false", quotes: "\"", hash: true)
    static let c = Language(
        "c", "C", line: ["//"], block: ("/*", "*/"), keywords: cKeywords, constants: "true false NULL", hash: true)
    static let cpp = Language(
        "cpp", "C++", line: ["//"], block: ("/*", "*/"),
        keywords: cKeywords
            + " class namespace template typename public private protected virtual override new delete this using try catch throw constexpr noexcept operator friend explicit mutable static_cast dynamic_cast reinterpret_cast const_cast final auto",
        constants: "true false NULL nullptr", hash: true)
    static let objc = Language(
        "objective-c", "Objective-C", line: ["//"], block: ("/*", "*/"),
        keywords: cKeywords + " self super id instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull",
        constants: "YES NO nil NULL true false", hash: true, at: true)
    static let java = Language(
        "java", "Java", line: ["//"], block: ("/*", "*/"),
        keywords:
            "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record yield sealed permits",
        constants: "true false null", triple: true, at: true)
    static let kotlin = Language(
        "kotlin", "Kotlin", line: ["//"], block: ("/*", "*/"),
        keywords:
            "abstract as break by catch class companion const constructor continue data do else enum external final finally for fun get if import in infix init inline interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend this throw try typealias val var vararg when where while",
        constants: "true false null", triple: true, at: true)
    static let ruby = Language(
        "ruby", "Ruby", line: ["#"],
        keywords:
            "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public",
        constants: "true false nil", at: true)
    static let php = Language(
        "php", "PHP", line: ["//", "#"], block: ("/*", "*/"),
        keywords:
            "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
        constants: "true false null TRUE FALSE NULL", dollar: true)
    static let shell = Language(
        "shellscript", "Shell", line: ["#"],
        keywords:
            "if then else elif fi case esac for while until do done in function return local export readonly declare set unset shift exit source alias echo cd printf test eval exec trap",
        constants: "true false", quotes: "\"'", multiline: "\"'", dollar: true)
    static let sql = Language(
        "sql", "SQL", line: ["--"], block: ("/*", "*/"),
        keywords:
            "select from where insert into values update set delete create table drop alter index view join left right inner outer full cross on group by order having limit offset as and or not null is in like between distinct union all primary key foreign references default exists case when then else end begin commit rollback with returning asc desc",
        constants: "true false NULL", caseInsensitive: true)
    static let json = Language("json", "JSON", line: ["//"], block: ("/*", "*/"), constants: "true false null", quotes: "\"", keys: true)
    static let yaml = Language(
        "yaml", "YAML", line: ["#"], constants: "true false null yes no on off True False Null", keys: true)
    static let toml = Language("toml", "TOML", line: ["#"], constants: "true false", triple: true, keys: true)
    static let css = Language(
        "css", "CSS", line: ["//"], block: ("/*", "*/"), keywords: "important", at: true, keys: true)
    static let markdown = Language("markdown", "Markdown", family: .markdown)
    static let html = Language("html", "HTML", family: .markup)
    static let xml = Language("xml", "XML", family: .markup)
    static let makefile = Language("makefile", "Makefile", line: ["#"], keywords: "ifeq ifneq ifdef ifndef else endif include define endef export override", dollar: true)
    static let dockerfile = Language(
        "dockerfile", "Dockerfile", line: ["#"],
        keywords: "from run cmd copy add env arg workdir expose entrypoint label user volume shell healthcheck onbuild stopsignal as",
        caseInsensitive: true, dollar: true)
    static let lua = Language(
        "lua", "Lua", line: ["--"],
        keywords: "and break do else elseif end for function goto if in local not or repeat return then until while",
        constants: "true false nil")
    static let ini = Language("ini", "Properties", line: ["#", ";"], keys: true)

    /// Every language, by name, for the status row's menu.
    public static let all: [Language] = [
        plain, c, cpp, css, dockerfile, go, html, java, javascript, json, kotlin, lua, makefile, markdown, objc, php,
        ini, python, ruby, rust, shell, sql, swift, toml, typescript, xml, yaml,
    ].sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    var keywordList: String { keywords.sorted().joined(separator: " ") }

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        let table: [(Language, String)] = [
            (swift, "swift"), (javascript, "js mjs cjs jsx"), (typescript, "ts mts cts tsx"), (python, "py pyi pyw"),
            (go, "go"), (rust, "rs"), (c, "c h"), (cpp, "cc cpp cxx hpp hh hxx mm"), (objc, "m"), (java, "java"),
            (kotlin, "kt kts"), (ruby, "rb rake gemspec"), (php, "php"), (shell, "sh bash zsh fish command"),
            (sql, "sql"), (json, "json jsonc json5 jsonl code-workspace"), (yaml, "yml yaml"), (toml, "toml"),
            (css, "css scss sass less"), (markdown, "md markdown mdx"), (html, "html htm vue svelte"),
            (xml, "xml plist svg xib storyboard entitlements csproj"), (lua, "lua"), (ini, "ini cfg conf properties env"),
            (makefile, "mk"),
        ]
        for (language, extensions) in table {
            for ext in extensions.split(separator: " ") { map[String(ext)] = language }
        }
        return map
    }()

    private static let byName: [String: Language] = [
        "Makefile": makefile, "makefile": makefile, "GNUmakefile": makefile, "Dockerfile": dockerfile,
        "Gemfile": ruby, "Rakefile": ruby, "Podfile": ruby, "Brewfile": ruby, ".zshrc": shell, ".bashrc": shell,
        ".bash_profile": shell, ".zprofile": shell, ".profile": shell, ".gitignore": ini, ".gitattributes": ini,
        ".editorconfig": ini, ".npmrc": ini, ".env": ini, "Package.resolved": json,
    ]

    /// The language for a file, from its name; plain text when unknown.
    public static func of(_ url: URL) -> Language {
        let name = url.lastPathComponent
        if let language = byName[name] { return language }
        if name.hasPrefix("Dockerfile") { return dockerfile }
        if name.hasPrefix(".env") { return ini }
        return byExtension[url.pathExtension.lowercased()] ?? plain
    }
}
