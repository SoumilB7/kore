import Foundation
import LinkProtocol

/// What a box is, found over one ssh session that reads only: its system and CPU, its
/// distribution, which tools it has (and the CLIs' versions), its service manager, its home and
/// free room, its git identity, and kore-host's version and facts when it's there. Kept per box
/// (`hosts/<box>/machine.json`), and found again only on Set up, Update, Set up agents or a
/// check asked for.
package struct BoxMachine: Codable, Equatable, Sendable {
    package enum System: String, Codable, Sendable { case linux, macOS, other }

    package var system = System.other
    /// `uname -sm` as it said it ("Linux aarch64").
    package var uname = ""
    /// `uname -m`: x86_64, aarch64, arm64.
    package var arch = ""
    /// The distribution's own name ("Ubuntu 24.04.1 LTS"), or "macOS 15.2".
    package var distro: String?
    /// os-release's `ID` and `ID_LIKE` (debian, ubuntu, fedora, alpine…).
    package var distroID: String?
    package var distroLike: String?
    /// `sw_vers -productVersion` on a Mac.
    package var macOS: String?
    /// The tools found, by name: their paths.
    package var tools: [String: String] = [:]
    /// Each CLI's `--version` line, by name.
    package var versions: [String: String] = [:]
    /// A systemd user manager answers (`systemctl --user`).
    package var systemdUser = false
    package var root = false
    package var shell: String?
    package var home: String?
    /// Free room in the home, in KB.
    package var freeKB: Int?
    /// `~/.local/bin/kore-host --version`'s line, when it's there and runs.
    package var koreHost: String?
    package var gitName: String?
    package var gitEmail: String?
    /// The CLIs' setup by name (`kore-host facts`); nil before kore-host is there.
    package var facts: AgentFacts?

    package init() {}

    // MARK: Finding it

    /// The tools looked for: what kore-host, sync and the agents' installers use.
    static let looked = [
        "systemctl", "launchctl", "loginctl", "rsync", "git", "curl", "tar", "unzip", "bash", "node", "npm", "gh", "claude", "codex", "brew",
        "apt-get", "dnf", "yum", "apk", "pacman", "zypper",
    ]

    /// The CLIs whose versions are compared with this Mac's.
    package static let compared = ["claude", "codex", "gh", "git", "node", "rsync"]

    /// The sh script that finds it, run as `sh -s`. `deep` adds the CLIs' versions and kore-host's
    /// facts (it runs them); without it only `uname`, os-release, `command -v` and the like run.
    package static func script(deep: Bool = true) -> String {
        var lines = [
            "# kore: detect",
            #"PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH:/usr/sbin:/sbin"; export PATH"#,
            #"echo "uname=$(uname -sm)""#,
            #"echo "uid=$(id -u)""#,
            #"echo "shell=$SHELL""#,
            #"echo "home=$HOME""#,
            #"[ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|ID|ID_LIKE)=' /etc/os-release | sed 's/^/os./'"#,
            #"command -v sw_vers >/dev/null 2>&1 && echo "macos=$(sw_vers -productVersion)""#,
            "for t in \(looked.joined(separator: " ")); do p=$(command -v \"$t\" 2>/dev/null) && echo \"has.$t=$p\"; done",
            #"command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 && echo "systemd.user=1""#,
            #"echo "free=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')""#,
            #"command -v git >/dev/null 2>&1 && { git config --global user.name | sed 's/^/git.name=/'; git config --global user.email | sed 's/^/git.email=/'; }"#,
            #"k="$HOME/.local/bin/kore-host"; [ -x "$k" ] && echo "korehost=$("$k" --version 2>&1 | head -n 1)""#,
        ]
        if deep {
            lines += [
                "for t in \(compared.joined(separator: " ")); do command -v \"$t\" >/dev/null 2>&1 && echo \"v.$t=$(\"$t\" --version 2>&1 </dev/null | head -n 1)\"; done",
                #"[ -x "$k" ] && "$k" facts 2>/dev/null | head -n 1 | sed 's/^/facts=/'"#,
            ]
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the script printed, read.
    package static func parse(_ output: String) -> BoxMachine? {
        var machine = BoxMachine()
        var sawUname = false
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<eq])
            let value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "uname":
                sawUname = true
                machine.uname = value
                let words = value.split(separator: " ").map(String.init)
                machine.arch = words.last ?? ""
                machine.system = words.first == "Linux" ? .linux : words.first == "Darwin" ? .macOS : .other
            case "uid": machine.root = value == "0"
            case "shell": machine.shell = value.isEmpty ? nil : value
            case "home": machine.home = value.isEmpty ? nil : value
            case "os.PRETTY_NAME": machine.distro = unquoted
            case "os.ID": machine.distroID = unquoted.lowercased()
            case "os.ID_LIKE": machine.distroLike = unquoted.lowercased()
            case "macos": machine.macOS = value
            case "systemd.user": machine.systemdUser = true
            case "free": machine.freeKB = Int(value)
            case "git.name": machine.gitName = value.isEmpty ? nil : value
            case "git.email": machine.gitEmail = value.isEmpty ? nil : value
            case "korehost": machine.koreHost = value.hasPrefix("kore-host ") ? value : nil
            case "facts": machine.facts = try? JSONDecoder().decode(AgentFacts.self, from: Data(value.utf8))
            default:
                if key.hasPrefix("has."), !value.isEmpty { machine.tools[String(key.dropFirst(4))] = value }
                if key.hasPrefix("v."), !value.isEmpty { machine.versions[String(key.dropFirst(2))] = value }
            }
        }
        if machine.system == .macOS { machine.distro = machine.macOS.map { "macOS " + $0 } ?? "macOS" }
        return sawUname ? machine : nil
    }

    // MARK: What it is

    package func has(_ tool: String) -> Bool { tools[tool] != nil }

    /// The CPU as people say it: arm64 or x86_64.
    package var cpu: String { ["aarch64", "arm64"].contains(arch) ? "arm64" : arch == "amd64" ? "x86_64" : arch }

    /// The hover card's line: "Linux · arm64 · Ubuntu 24.04.1 LTS", "macOS 15.2 · arm64".
    package var kind: String {
        switch system {
        case .linux: (["Linux", cpu] + (distro.map { [$0] } ?? [])).joined(separator: " · ")
        case .macOS: [distro ?? "macOS", cpu].joined(separator: " · ")
        case .other: uname
        }
    }

    /// The kore-host binary it runs ("linux-x86_64", "macos-arm64"); nil for one Kore has none for.
    package var platform: String? {
        switch (system, cpu) {
        case (.linux, "x86_64"): "linux-x86_64"
        case (.linux, "arm64"): "linux-aarch64"
        case (.macOS, "arm64"): "macos-arm64"
        case (.macOS, "x86_64"): "macos-x86_64"
        default: nil
        }
    }

    /// How kore-host will stay running there.
    package var service: String {
        switch system {
        case .macOS: "launchd"
        case .linux: systemdUser ? "systemd" : "on demand"
        case .other: "none"
        }
    }

    /// kore-host's version there ("0.2.3"), from its `--version` line.
    package var koreHostVersion: String? {
        koreHost?.split(separator: " ").dropFirst().first.map(String.init)
    }

    /// The oldest macOS kore-host runs on.
    static let oldestMacOS = 15

    /// Why kore-host can't run here, in a line; nil when it can.
    package func unsupported(_ name: String) -> String? {
        switch system {
        case .other: return "\(name) runs \(uname.isEmpty ? "a system" : uname) · Kore runs on Linux and macOS boxes"
        case .linux where platform == nil: return "\(name) has a \(arch) CPU · Kore runs on x86_64 and arm64"
        case .macOS:
            if platform == nil { return "\(name) has a \(arch) CPU · Kore runs on arm64 and x86_64" }
            if let major = macOS?.split(separator: ".").first.flatMap({ Int($0) }), major < Self.oldestMacOS {
                return "\(name) runs macOS \(macOS ?? "") · Kore needs macOS \(Self.oldestMacOS) or later"
            }
            return nil
        default: return nil
        }
    }

    // MARK: Tools it lacks

    /// The package manager's install line for `package` (with sudo unless it's root); nil when
    /// there's none Kore knows.
    package func installCommand(_ package: String) -> String? {
        let sudo = root ? "" : "sudo "
        if system == .macOS {
            if has("brew") { return "brew install \(package)" }
            return package == "git" ? "xcode-select --install" : nil
        }
        let family = [distroID ?? "", distroLike ?? ""].joined(separator: " ")
        if has("apt-get") || family.contains("debian") || family.contains("ubuntu") { return "\(sudo)apt-get install -y \(package)" }
        if has("dnf") { return "\(sudo)dnf install -y \(package)" }
        if has("yum") { return "\(sudo)yum install -y \(package)" }
        if has("apk") { return "\(sudo)apk add \(package)" }
        if has("pacman") { return "\(sudo)pacman -S --noconfirm \(package)" }
        if has("zypper") { return "\(sudo)zypper install -y \(package)" }
        return nil
    }

    /// Whether `installCommand` runs without asking for a password (Homebrew, or root).
    package func installsWithoutPassword(_ package: String) -> Bool {
        guard let command = installCommand(package) else { return false }
        return !command.hasPrefix("sudo ") && !command.hasPrefix("xcode-select")
    }

    /// A tool the box needs and lacks, in a line ("rsync isn't on mybox · sync needs it"), with
    /// the command that adds it. Nil when nothing's missing. The most needed first.
    package func missing(_ name: String) -> (line: String, tool: String, command: String?)? {
        for (tool, why) in [("rsync", "sync needs it"), ("git", "the CLIs need it")] where !has(tool) {
            return ("\(tool) isn't on \(name) · \(why)", tool, installCommand(tool))
        }
        return nil
    }

    // MARK: Kept per box

    static func file(_ alias: String, root: URL) -> URL { HostCache(alias: alias, root: root).folder.appendingPathComponent("machine.json") }

    package static func cached(_ alias: String, root: URL = HostCache.root()) -> BoxMachine? {
        (try? Data(contentsOf: file(alias, root: root))).flatMap { try? JSONDecoder().decode(BoxMachine.self, from: $0) }
    }

    package func keep(_ alias: String, root: URL = HostCache.root()) {
        let url = Self.file(alias, root: root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The major and minor of a `--version` line ("2.1.322" → "2.1").
    package static func majorMinor(_ line: String) -> String? {
        let scalars = Array(line)
        var i = 0
        while i < scalars.count {
            if scalars[i].isNumber {
                var j = i
                while j < scalars.count, scalars[j].isNumber || scalars[j] == "." { j += 1 }
                let parts = String(scalars[i..<j]).split(separator: ".")
                if parts.count >= 2 { return parts[0] + "." + parts[1] }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }
}
