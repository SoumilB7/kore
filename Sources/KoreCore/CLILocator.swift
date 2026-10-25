import Foundation

/// Where the claude and codex CLIs can be on a Mac: one fixed list of known places, in order. Each
/// place is a path, or one folder listed one level deep (a version folder, an editor's
/// extensions); the disk is never crawled, and no app's container is read. A candidate counts
/// only once its `--version` answers (`CLIExecutable`).
public enum CLILocator {
    /// The CLIs the list knows; any other name is looked up on PATH only.
    public static let known: Set<String> = ["claude", "codex"]

    public struct Candidate: Equatable, Sendable {
        public let url: URL
        /// Which place it came from, by id (`path`, `native`, `nvm`, `app`, `vscode`…): the only
        /// thing logs record about it.
        public let source: String
        /// It sits in a bin folder with the tools it may need (an npm install's `node`): that
        /// folder joins its PATH.
        public let inBinFolder: Bool
    }

    /// The places' roots: the real ones in Kore, a temp tree in tests.
    public struct Places: Sendable {
        public var home: URL
        /// The login shell's PATH, in order.
        public var path: [String]
        /// The binary picked with Locate…, if any.
        public var chosen: URL?
        public var system: [String]
        public var applications: [URL]

        public init(home: URL, path: [String], chosen: URL? = nil, system: [String]? = nil, applications: [URL]? = nil) {
            self.home = home
            self.path = path
            self.chosen = chosen
            self.system = system ?? ["/opt/homebrew/bin", "/usr/local/bin"]
            self.applications = applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        }
    }

    /// Every executable candidate for `name`, best first, each binary once (links resolved).
    public static func candidates(_ name: String, in places: Places) -> [Candidate] {
        guard known.contains(name) else { return [] }
        let files = FileManager.default
        let claude = name == "claude"
        let home = places.home.path
        var found: [Candidate] = []
        var seen = Set<String>()

        func add(_ path: String, _ source: String, bin: Bool = false) {
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                files.isExecutableFile(atPath: path), seen.insert(real(path)).inserted
            else { return }
            found.append(Candidate(url: URL(fileURLWithPath: path), source: source, inBinFolder: bin))
        }
        /// A bin folder: the CLI in it, and an npm install's native `claude.exe` beside it.
        func binFolder(_ dir: String, _ source: String) {
            add(dir + "/" + name, source, bin: true)
            if claude {
                let prefix = (dir as NSString).deletingLastPathComponent
                add(prefix + "/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", source)
            }
        }

        // 1 · Locate…'s pick. 2 · The login shell's PATH. 3 · ~/.local/bin. 4 · Homebrew's.
        if let chosen = places.chosen { add(chosen.path, "chosen") }
        for dir in places.path where !dir.isEmpty { binFolder(dir, "path") }
        binFolder(home + "/.local/bin", "local-bin")
        for dir in places.system { binFolder(dir, "homebrew") }
        // 5 · Claude's native installer: its versions (a binary each, newest first), then the old
        // local install. 6 · Codex's standalone one.
        if claude {
            let versions = home + "/.local/share/claude/versions"
            for entry in newestFirst(listing(versions), after: "") {
                add(versions + "/" + entry, "native")
                add(versions + "/" + entry + "/claude", "native")
            }
            add(home + "/.claude/local/claude", "native-local")
        } else {
            add(home + "/.codex/packages/standalone/current/bin/codex", "standalone")
        }
        // 7 · Node version managers' and package managers' globals.
        let nvm = home + "/.nvm/versions/node"
        for version in newestFirst(listing(nvm), after: "v") { binFolder(nvm + "/" + version + "/bin", "nvm") }
        binFolder(home + "/.volta/bin", "volta")
        binFolder(home + "/.asdf/shims", "asdf")
        binFolder(home + "/Library/pnpm", "pnpm")
        binFolder(home + "/.bun/bin", "bun")
        // 8 · An app bundle that ships the CLI. Names are matched as listed, case and all: the
        // volume ignores case, and `Contents/MacOS/Claude` is the desktop app itself.
        let bundle = claude ? "Claude.app" : "Codex.app"
        let names = claude ? ["claude", "claude-code"] : ["codex"]
        for root in places.applications {
            for part in ["Contents/Resources", "Contents/MacOS"] {
                let dir = root.appendingPathComponent(bundle).path + "/" + part
                let entries = Set(listing(dir))
                for binary in names where entries.contains(binary) { add(dir + "/" + binary, "app") }
            }
        }
        // 9 · An editor extension's bundled binary, newest extension first.
        let prefix = claude ? "anthropic.claude-code-" : "openai.chatgpt-"
        let inside =
            claude
            ? ["resources/native-binary/claude", "resources/native-binaries/darwin-arm64/claude", "resources/native-binaries/darwin-x64/claude"]
            : ["bin/macos-aarch64/codex", "bin/macos-x86_64/codex"]
        for (folder, source) in [(".vscode/extensions", "vscode"), (".cursor/extensions", "cursor"), (".windsurf/extensions", "windsurf")] {
            let root = home + "/" + folder
            for ext in newestFirst(listing(root).filter { $0.hasPrefix(prefix) }, after: prefix) {
                for path in inside { add(root + "/" + ext + "/" + path, source) }
            }
        }
        return found
    }

    /// A folder's entries, one level, hidden ones left out; none when it isn't there.
    private static func listing(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Names by the version after `prefix` ("2.1.3", "v22.4.0", "1.0.2-darwin-arm64"), newest first.
    static func newestFirst(_ names: [String], after prefix: String) -> [String] {
        names.sorted { lhs, rhs in
            let a = version(lhs, after: prefix), b = version(rhs, after: prefix)
            return a == b ? lhs > rhs : b.lexicographicallyPrecedes(a)
        }
    }

    /// The leading dotted number after `prefix`, as numbers.
    static func version(_ name: String, after prefix: String) -> [Int] {
        let rest = name.hasPrefix(prefix) ? name.dropFirst(prefix.count) : Substring(name)
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        return digits.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
