import Foundation
import KoreCore
import LinkProtocol

/// A CLI Kore puts on a box itself, under the user's home and without sudo: claude through its
/// own installer, codex through its npm package (a user prefix) or its standalone binary, and
/// gh's release binary. Each lands where the box's service looks (`~/.local/bin`,
/// `~/.npm-global/bin`). Nothing of this Mac's (no login, no key) goes with it: each signs in on
/// the box.
package enum BoxAgent: String, CaseIterable, Sendable, Codable {
    case claude, codex, gh

    /// Its key among the box's logins (`BoxAccounts`: `claude`, `codex`, and `gh` for GitHub's).
    package var account: String { rawValue }

    /// The script that installs (or updates) it there, run as `sh -s`; or why Kore can't, in a
    /// line with what to add first.
    package func install(on machine: BoxMachine, name: String) -> Result<String, BoxSetup.Failure> {
        func need(_ tool: String) -> BoxSetup.Failure {
            let command = machine.installCommand(tool)
            return BoxSetup.Failure(
                message: "\(tool) isn't on \(name) · \(rawValue)'s install needs it",
                fix: command.map { machine.installsWithoutPassword(tool) ? .install(tool) : .copy($0) })
        }
        let start = "set -e\nmkdir -p \"$HOME/.local/bin\"\nt=$(mktemp -d)\ntrap 'rm -rf \"$t\"' EXIT\n"
        switch self {
        case .claude:
            guard machine.has("curl") else { return .failure(need("curl")) }
            guard machine.has("bash") else { return .failure(need("bash")) }
            return .success(start + "curl -fsSL https://claude.ai/install.sh -o \"$t/install.sh\"\nbash \"$t/install.sh\"\n")
        case .codex:
            if machine.has("npm") {
                return .success(start + "npm install -g --prefix \"$HOME/.npm-global\" @openai/codex\n")
            }
            guard let target = Self.codexTarget(machine.platform) else { return .failure(BoxSetup.Failure(message: "codex has no build for \(machine.kind)")) }
            guard machine.has("curl") else { return .failure(need("curl")) }
            guard machine.has("tar") else { return .failure(need("tar")) }
            return .success(
                start + "curl -fsSL https://github.com/openai/codex/releases/latest/download/codex-\(target).tar.gz | tar -xz -C \"$t\"\n"
                    + "mv -f \"$t/codex-\(target)\" \"$HOME/.local/bin/codex\"\nchmod 755 \"$HOME/.local/bin/codex\"\n")
        case .gh:
            guard machine.has("curl") else { return .failure(need("curl")) }
            let latest = #"v=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"#
                + "\n[ -n \"$v\" ] || { echo \"couldn't read gh's latest release\" >&2; exit 1; }\n"
            switch machine.platform {
            case "linux-x86_64"?, "linux-aarch64"?:
                guard machine.has("tar") else { return .failure(need("tar")) }
                let arch = machine.platform == "linux-x86_64" ? "amd64" : "arm64"
                return .success(
                    start + latest + "curl -fsSL \"https://github.com/cli/cli/releases/download/v$v/gh_${v}_linux_\(arch).tar.gz\" | tar -xz -C \"$t\"\n"
                        + "mv -f \"$t/gh_${v}_linux_\(arch)/bin/gh\" \"$HOME/.local/bin/gh\"\n")
            case "macos-arm64"?, "macos-x86_64"?:
                guard machine.has("unzip") else { return .failure(need("unzip")) }
                return .success(
                    start + latest + "curl -fsSL -o \"$t/gh.zip\" \"https://github.com/cli/cli/releases/download/v$v/gh_${v}_macOS_universal.zip\"\n"
                        + "unzip -q \"$t/gh.zip\" -d \"$t\"\nmv -f \"$t/gh_${v}_macOS_universal/bin/gh\" \"$HOME/.local/bin/gh\"\n")
            default:
                return .failure(BoxSetup.Failure(message: "gh has no build for \(machine.kind)"))
            }
        }
    }

    /// codex's standalone build for a platform.
    static func codexTarget(_ platform: String?) -> String? {
        switch platform {
        case "linux-x86_64": "x86_64-unknown-linux-musl"
        case "linux-aarch64": "aarch64-unknown-linux-musl"
        case "macos-arm64": "aarch64-apple-darwin"
        case "macos-x86_64": "x86_64-apple-darwin"
        default: nil
        }
    }
}

/// Who a CLI is signed in as, on one side: nil `who` when it's signed in without saying.
package struct BoxLogin: Equatable, Sendable {
    package var signedIn: Bool
    package var who: String?

    package init(signedIn: Bool, who: String? = nil) {
        self.signedIn = signedIn
        self.who = who
    }

    /// From the box's line ("Signed in as a@b.c.", "codex isn't signed in.").
    package static func said(_ line: BoxAccounts.Line) -> BoxLogin? {
        guard let on = line.signedIn else { return nil }
        let who = line.said.flatMap { said -> String? in
            guard let range = said.range(of: "Signed in as ") else { return nil }
            let rest = said[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return rest.isEmpty ? nil : rest
        }
        return BoxLogin(signedIn: on, who: who)
    }
}

/// What a box lacks next to this Mac, so its chats behave the same: each CLI there and its
/// version, each login, the CLIs' MCP servers, claude's skills, plugins and agents (names only),
/// the git identity and the default models. Compared once from what each side says, read only;
/// nothing of the Mac's setup is copied (a server's entry can carry a secret).
package struct BoxParity: Equatable, Sendable {
    package enum Fix: Equatable, Sendable {
        /// Install or update the CLI there (`BoxAgent`).
        case install(BoxAgent)
        /// Sign the CLI in there.
        case signIn(BoxAgent)
        /// The Mac's git name and email, set on the box (`git config --global`).
        case gitIdentity(name: String?, email: String?)
        /// A tool that needs no password to install there (Homebrew).
        case tool(String)
        /// A command for the user's own Terminal (it needs sudo).
        case copy(String)
    }

    package struct Difference: Equatable, Sendable, Identifiable {
        package var id: String
        package var line: String
        package var fix: Fix?

        package init(id: String, line: String, fix: Fix? = nil) {
            self.id = id
            self.line = line
            self.fix = fix
        }
    }

    package var differences: [Difference] = []

    package init(differences: [Difference] = []) { self.differences = differences }

    package var isEmpty: Bool { differences.isEmpty }

    /// The box against this Mac. `logins` are each side's by CLI (`claude`, `codex`, `gh`), when
    /// known; a side that hasn't said is left out of that compare.
    package static func compare(
        mac: BoxMachine, box: BoxMachine, name: String, macLogins: [String: BoxLogin] = [:], boxLogins: [String: BoxLogin] = [:]
    ) -> BoxParity {
        var out: [Difference] = []
        func add(_ id: String, _ line: String, _ fix: Fix? = nil) { out.append(Difference(id: id, line: line, fix: fix)) }

        for tool in BoxMachine.compared {
            let here = mac.versions[tool] ?? mac.tools[tool]
            guard here != nil else { continue }
            let agent = BoxAgent(rawValue: tool)
            guard box.has(tool) || box.versions[tool] != nil else {
                let fix: Fix? =
                    agent.map { .install($0) }
                    ?? box.installCommand(tool).map { box.installsWithoutPassword(tool) ? .tool(tool) : .copy($0) }
                add("tool." + tool, "\(tool) isn't on \(name)", fix)
                continue
            }
            // rsync's builds differ by kind (openrsync on a Mac): there only presence counts.
            guard tool != "rsync", let mine = mac.versions[tool].flatMap(BoxMachine.majorMinor),
                let theirs = box.versions[tool].flatMap(BoxMachine.majorMinor), mine != theirs
            else { continue }
            add("version." + tool, "\(tool) \(theirs) on \(name), \(mine) here", agent.map { .install($0) })
        }

        for agent in BoxAgent.allCases {
            guard let mine = macLogins[agent.account], mine.signedIn, box.has(agent.rawValue) || box.versions[agent.rawValue] != nil,
                let theirs = boxLogins[agent.account]
            else { continue }
            if !theirs.signedIn {
                add("login." + agent.rawValue, "\(agent.rawValue) isn't signed in on \(name)", .signIn(agent))
            } else if let a = mine.who, let b = theirs.who, a.lowercased() != b.lowercased() {
                add("login." + agent.rawValue, "\(agent.rawValue) is \(b) on \(name), \(a) here", .signIn(agent))
            }
        }

        if mac.gitName != nil || mac.gitEmail != nil, box.has("git"), mac.gitName != box.gitName || mac.gitEmail != box.gitEmail {
            let who = [mac.gitName, mac.gitEmail.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            let line = box.gitName == nil && box.gitEmail == nil ? "git on \(name) has no name · \(who) here" : "git on \(name) commits as someone else · \(who) here"
            add("git.identity", line, .gitIdentity(name: mac.gitName, email: mac.gitEmail))
        }

        if let mine = mac.facts, let theirs = box.facts {
            func lacking(_ id: String, _ what: String, _ a: [String], _ b: [String]) {
                let gone = a.filter { !b.contains($0) }
                guard !gone.isEmpty else { return }
                let shown = gone.prefix(3).joined(separator: ", ") + (gone.count > 3 ? " +\(gone.count - 3)" : "")
                add(id, "\(what) not on \(name): \(shown)")
            }
            lacking("claude.mcp", "claude MCP", mine.claudeMCP, theirs.claudeMCP)
            lacking("claude.skills", "claude skills", mine.claudeSkills, theirs.claudeSkills)
            lacking("claude.plugins", "claude plugins", mine.claudePlugins, theirs.claudePlugins)
            lacking("claude.agents", "claude agents", mine.claudeAgents, theirs.claudeAgents)
            lacking("codex.mcp", "codex MCP", mine.codexMCP, theirs.codexMCP)
            for (cli, a, b) in [("claude", mine.claudeModel, theirs.claudeModel), ("codex", mine.codexModel, theirs.codexModel)] {
                guard let a, a != b else { continue }
                add(cli + ".model", "\(cli)'s default model is \(b ?? "its own") on \(name), \(a) here")
            }
        }
        return BoxParity(differences: out)
    }

    /// The git identity set on the box: `git config --global` for each, quoted.
    package static func gitScript(name: String?, email: String?) -> String {
        var lines = ["set -e"]
        if let name { lines.append("git config --global user.name " + ShellQuote.single(name)) }
        if let email { lines.append("git config --global user.email " + ShellQuote.single(email)) }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// This Mac, found the same way as a box (the same script, run here) with its CLIs' setup read
/// in place: what a box is compared with.
package enum MacMachine {
    package static func find() async -> BoxMachine? {
        let ran = await BoxShell.local(BoxMachine.script(deep: true))
        var machine = BoxMachine.parse(ran.output)
        machine?.facts = AgentFacts.read(home: FileManager.default.homeDirectoryForCurrentUser)
        return machine
    }
}

extension BoxShell {
    /// An sh script run on this Mac.
    package static func local(_ script: String) async -> BoxRan {
        await BoxShell(ssh: "/bin/sh").process(["-s"], input: script)
    }
}
