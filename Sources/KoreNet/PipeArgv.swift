import Foundation

/// What a pipe may run on the far end (phase 18 §1 "Bulk", rrsync-grade): `rsync --server
/// [--sender] <options> . <path>…` and nothing else, as rsync's `-e` hands its remote command to
/// `kore pipe`. Both forms rsync clients send are read (spike 0f): openrsync's separate flags
/// (`-g -l -o -p -D -r -t --dirs`) and rsync 3's one cluster with its capability letters
/// (`-logDtpre.iLsfxCIvu`). The words were meant for a shell, so each is unquoted as one would
/// (single and double quotes, backslashes), and any word a shell would expand or split is
/// refused. What's checked here is the words alone; where each path leads (inside the box's
/// home or a served folder, links resolved) is the box's to check.
package struct PipeArgv: Equatable, Sendable {
    /// The far end sends (a pull): `--sender`.
    package var sender: Bool
    /// The options as given, unquoted, `--server` and `--sender` left out.
    package var options: [String]
    /// The paths after `.`, unquoted, each absolute and without `..`.
    package var paths: [String]

    /// Options the far end always runs with, after the client's (rsync takes the last word):
    /// devices and specials are never made. Not `--munge-links` or `--safe-links`: they drop or
    /// rewrite the user's own links (every link a Mac sends, with both: real rsync 3.5,
    /// 2026-11-25). What keeps a copy inside its folder is the argv check, each path where it
    /// really leads, no option that follows links there (L, k, K, `--no-implied-dirs`), and rsync,
    /// which never writes through a folder link it finds.
    package static let forced = ["--no-specials", "--no-devices"]
    /// The far end's own I/O timeout when the client gave none (openrsync never passes one).
    package static let serverTimeout = 60

    /// Letters a short option (or the part of rsync 3's cluster before its `e.`) may hold. Not
    /// L, k, K, H (links followed or kept as hard links out of place), nor s (the paths would come
    /// over the protocol, past this check).
    static let shortLetters = Set("glopDrtzcdRvxuSWIniOJmCb")
    /// Long options taken as they are.
    static let longFlags: Set<String> = [
        "--dirs", "--relative", "--delete", "--delete-before", "--delete-during", "--delete-after", "--delete-delay",
        "--partial", "--from0", "--compress", "--checksum", "--numeric-ids", "--size-only", "--ignore-times", "--inplace", "--append",
        "--mkpath", "--existing", "--ignore-existing", "--force", "--omit-dir-times", "--omit-link-times", "--prune-empty-dirs",
        "--whole-file", "--sparse", "--update", "--one-file-system", "--no-specials", "--no-devices",
    ]
    /// Long options with a value, and what the value may be.
    static let longValues: [String: @Sendable (String) -> Bool] = [
        "--timeout": { Int($0).map { (0...86_400).contains($0) } ?? false },
        "--compress-level": { Int($0).map { (0...22).contains($0) } ?? false },
        "--files-from": { $0 == "-" },
        "--modify-window": { Int($0) != nil },
        "--max-size": { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } },
        "--min-size": { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } },
        "--checksum-choice": { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "," } },
        "--compress-choice": { $0.allSatisfy { $0.isLetter || $0.isNumber } },
    ]
    /// Named in the plan as refused; kept apart so the refusal says which.
    static let refusedLong: Set<String> = [
        "-e", "--rsh", "--rsync-path", "--remove-source-files", "--remove-sent-files", "--log-file", "--log-file-format", "--backup-dir",
        "--link-dest", "--compare-dest", "--copy-dest", "--temp-dir", "--partial-dir", "--copy-links", "--copy-dirlinks", "--keep-dirlinks",
        "--hard-links", "--secluded-args", "--protect-args", "--daemon", "--config", "--write-batch", "--read-batch", "--only-write-batch",
        "--include-from", "--exclude-from", "--filter", "--include", "--exclude", "--chown", "--usermap", "--groupmap", "--chmod",
    ]

    package enum Refusal: Error, Equatable, CustomStringConvertible {
        case notRsync
        case notServer
        case refused(String)
        case unknown(String)
        case badValue(String)
        case shell(String)
        case noPaths
        case badPath(String)

        package var description: String {
            switch self {
            case .notRsync: "only rsync runs over a pipe"
            case .notServer: "only rsync --server runs over a pipe"
            case .refused(let option): "\(option) isn't allowed over a pipe"
            case .unknown(let option): "\(option) isn't an option a pipe takes"
            case .badValue(let option): "\(option) has a value a pipe doesn't take"
            case .shell(let word): "\(word.prefix(40)) is something a shell would expand"
            case .noPaths: "no path to copy"
            case .badPath(let path): "\(path.prefix(80)) isn't an absolute path inside a folder"
            }
        }
    }

    /// Reads the words rsync gave its remote shell after the host: `rsync --server …`.
    package static func parse(_ words: [String]) throws(Refusal) -> PipeArgv {
        var plain: [String] = []
        for word in words { plain.append(try unquote(word)) }
        guard let program = plain.first, program == "rsync" || program.hasSuffix("/rsync") else { throw .notRsync }
        var rest = plain.dropFirst()
        guard rest.first == "--server" else { throw .notServer }
        rest = rest.dropFirst()
        var sender = false
        var options: [String] = []
        var paths: [String] = []
        var dotSeen = false
        for word in rest {
            if dotSeen {
                paths.append(try path(word))
                continue
            }
            switch word {
            case ".": dotSeen = true
            case "--sender": sender = true
            case "--server": throw .refused(word)
            // A path before `.`: not the form either client sends.
            case let path where !path.hasPrefix("-"): throw .noPaths
            default:
                try option(word)
                options.append(word)
            }
        }
        guard dotSeen, !paths.isEmpty else { throw .noPaths }
        return PipeArgv(sender: sender, options: options, paths: paths)
    }

    /// One option word, as either client sends it.
    static func option(_ word: String) throws(Refusal) {
        if word.hasPrefix("--") {
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            if refusedLong.contains(name) { throw .refused(name) }
            if let valid = longValues[name] {
                guard let eq = word.firstIndex(of: "="), valid(String(word[word.index(after: eq)...])) else { throw .badValue(name) }
                return
            }
            guard longFlags.contains(word) else { throw .unknown(name) }
            return
        }
        guard word.hasPrefix("-"), word.count > 1 else { throw .unknown(word) }
        // `-e` alone names a remote shell; rsync 3's `e` is always followed by its capabilities.
        if word == "-e" { throw .refused(word) }
        // rsync 3's cluster: the letters, then `e` and its capabilities (`e.iLsfxCIvu`), which
        // say what this rsync speaks, not what it does.
        var letters = word.dropFirst()
        if let e = letters.firstIndex(of: "e") {
            let capabilities = letters[letters.index(after: e)...]
            guard capabilities.allSatisfy({ $0.isLetter || $0 == "." }) else { throw .unknown(word) }
            letters = letters[..<e]
        }
        for letter in letters {
            if "LkKHs".contains(letter) { throw .refused("-" + String(letter)) }
            guard shortLetters.contains(letter) else { throw .unknown("-" + String(letter)) }
        }
    }

    /// A path after `.`: absolute, no `..`, no NUL.
    static func path(_ word: String) throws(Refusal) -> String {
        guard word.hasPrefix("/"), !word.contains("\0"), !word.split(separator: "/").contains("..") else { throw .badPath(word) }
        return word
    }

    /// The far end's command, as it runs: rsync, `--server`, `--sender` when it sends, the
    /// client's options, the forced ones, a timeout of its own when none was given, `.`, and the
    /// paths as the box resolved them.
    package func command(rsync: String = "rsync", paths resolved: [String]? = nil, forced: [String] = PipeArgv.forced) -> [String] {
        let timeout = options.contains { $0.hasPrefix("--timeout=") } ? [] : ["--timeout=\(Self.serverTimeout)"]
        return [rsync, "--server"] + (sender ? ["--sender"] : []) + options + forced + timeout + ["."] + (resolved ?? paths)
    }

    /// A word as the shell it was written for would read it, without expanding anything: quotes
    /// and backslashes taken off; a word that would expand, split or redirect is refused.
    package static func unquote(_ word: String) throws(Refusal) -> String {
        var out = ""
        var chars = word.makeIterator()
        enum Quote { case none, single, double }
        var quote = Quote.none
        while let c = chars.next() {
            switch quote {
            case .single:
                if c == "'" { quote = .none } else { out.append(c) }
            case .double:
                switch c {
                case "\"": quote = .none
                case "\\":
                    guard let next = chars.next() else { throw .shell(word) }
                    if "\"\\$`".contains(next) { out.append(next) } else { out.append(c); out.append(next) }
                case "$", "`": throw .shell(word)
                default: out.append(c)
                }
            case .none:
                switch c {
                case "'": quote = .single
                case "\"": quote = .double
                case "\\":
                    guard let next = chars.next(), next != "\n" else { throw .shell(word) }
                    out.append(next)
                case "$", "`", ";", "|", "&", "<", ">", "(", ")", "*", "?", "[", "]", "{", "}", "~", "#", " ", "\t", "\n":
                    throw .shell(word)
                default: out.append(c)
                }
            }
        }
        guard quote == .none else { throw .shell(word) }
        return out
    }
}
