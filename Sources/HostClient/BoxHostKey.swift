import Foundation

/// A box's SSH host key on first contact: the key the box shows, captured by ssh itself into a
/// scratch known_hosts (`StrictHostKeyChecking=accept-new`, through the alias's own config:
/// ProxyCommand, HostKeyAlias, port), its fingerprint as ssh prints it, and on Trust the very
/// lines ssh wrote, added to the user's known_hosts: what `ssh -o StrictHostKeyChecking=accept-new`
/// would have done. Trust looks again first and adds nothing unless the box still shows the key
/// that was shown. A changed key never gets here (it's never offered).
package enum BoxHostKey {
    /// What the line offers: the fingerprints, and the lines Trust adds.
    package struct Offer: Equatable, Sendable {
        /// The SSH alias (or destination) the key is for.
        package var ssh: String
        /// "ED25519 SHA256:…", one per key the box showed.
        package var fingerprints: [String]
        /// known_hosts lines, as ssh wrote them.
        package var lines: [String]
        /// The command for the user's own Terminal ("ssh mybox-cf"), for Copy.
        package var command: String
        /// It's the key this box had before over this alias (`BoxList.keysSeen`): the alias points
        /// at a new address (a Cloudflare quick tunnel's new hostname), not a new box.
        package var moved = false
        /// Set up was under way when the key stopped it: Trust goes on with it.
        package var setUp = false

        package init(ssh: String, fingerprints: [String], lines: [String], command: String, moved: Bool = false, setUp: Bool = false) {
            self.ssh = ssh
            self.fingerprints = fingerprints
            self.lines = lines
            self.command = command
            self.moved = moved
            self.setUp = setUp
        }

        /// The line: "mybox-cf's host key is new · ED25519 SHA256:…", or, a box seen before over
        /// it, "mybox-cf now points at a new address · ED25519 SHA256:…".
        package var line: String {
            let key = fingerprints.first ?? "a key Kore couldn't read"
            return (moved ? "\(ssh) now points at a new address · " : "\(ssh)'s host key is new · ") + key
        }
    }

    /// ssh-keygen (tests: a stand-in).
    package static let keygen = "/usr/bin/ssh-keygen"

    /// The key `ssh` sees for `alias` now, and its fingerprints: nil when ssh couldn't get one.
    package static func scan(_ alias: String, shell: BoxShell, keygen: String = keygen) async -> (fingerprints: [String], lines: [String])? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-hostkey-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard FileManager.default.createFile(atPath: scratch.path, contents: Data()) else { return nil }
        // Auth is never tried past "none": only the key exchange matters, nothing runs there.
        let options = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=" + scratch.path,
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no", "-o", "PreferredAuthentications=none",
        ]
        _ = await BoxShell.process(shell.ssh, Array(await BoxSSH.argv(alias, program: shell.ssh, options: options, ["exit 0"]).dropFirst()), limit: shell.reach)
        let written = (try? String(contentsOf: scratch, encoding: .utf8)) ?? ""
        let lines = written.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return nil }
        let printed = await BoxShell.process(keygen, ["-l", "-f", scratch.path])
        let fingerprints = fingerprints(printed.output)
        guard printed.ok, !fingerprints.isEmpty else { return nil }
        return (fingerprints, lines)
    }

    /// `ssh-keygen -l` lines ("256 SHA256:abc… host (ED25519)") as "ED25519 SHA256:abc…".
    package static func fingerprints(_ output: String) -> [String] {
        var out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            guard let print = words.first(where: { $0.hasPrefix("SHA256:") }) else { continue }
            let type = words.last.flatMap { $0.hasPrefix("(") && $0.hasSuffix(")") ? String($0.dropFirst().dropLast()) : nil }
            let shown = (type.map { $0 + " " } ?? "") + print
            if !out.contains(shown) { out.append(shown) }
        }
        return out
    }

    /// The keys in known_hosts lines ("ssh-ed25519 AAAA…"), whatever they call the host: with
    /// `HashKnownHosts` ssh writes its name under a new salt each time. A marked line (`@revoked`,
    /// `@cert-authority`) is no host's key.
    package static func keys(_ lines: [String]) -> Set<String> {
        Set(lines.compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3, !line.hasPrefix("#"), !line.hasPrefix("@") else { return nil }
            return words[1] + " " + words[2]
        })
    }

    /// The keys ssh already trusts `alias` with: its known_hosts lines for the name ssh looks it
    /// up by now (`HostKeyAlias`, else its host and port), hashed or not.
    package static func known(_ alias: String, shell: BoxShell, file: String? = nil, keygen: String = keygen) async -> Set<String> {
        let said = await BoxShell.process(shell.ssh, Array(await BoxSSH.argv(alias, program: shell.ssh, options: ["-G"], []).dropFirst()))
        guard said.ok, let name = knownHostsName(config: said.output) else { return [] }
        let found = await BoxShell.process(keygen, ["-F", name, "-f", file ?? knownHostsFile(config: said.output, home: NSHomeDirectory())])
        return found.ok ? keys(found.output.split(whereSeparator: \.isNewline).map(String.init)) : []
    }

    /// The name ssh looks a host up by in known_hosts, from `ssh -G`.
    package static func knownHostsName(config: String) -> String? {
        var said: [String: String] = [:]
        for line in config.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            if words.count >= 2, said[words[0].lowercased()] == nil { said[words[0].lowercased()] = words[1] }
        }
        if let alias = said["hostkeyalias"], alias.lowercased() != "none" { return alias }
        guard let host = said["hostname"] else { return nil }
        guard let port = said["port"], port != "22" else { return host }
        return "[\(host)]:\(port)"
    }

    /// What a key means for a box whose keys were `before`. One of a kind not seen before counts
    /// as different: nothing says it's the same box.
    package enum Against: Equatable, Sendable { case unknown, same, different }

    package static func against(_ before: Set<String>, _ lines: [String]) -> Against {
        guard !before.isEmpty else { return .unknown }
        let now = keys(lines)
        return !now.isEmpty && now.isSubset(of: before) ? .same : .different
    }

    /// The line for a box that shows another key than it had: never a Trust.
    package static func differentLine(_ ssh: String, _ fingerprints: [String]) -> String {
        "\(ssh) shows a different key than before · this could be an attack, so Kore won't trust it · check with the box · "
            + (fingerprints.first ?? "a key Kore couldn't read")
    }

    /// The known_hosts file ssh writes for `alias` (`ssh -G`'s first `userknownhostsfile`, `~`
    /// expanded); `~/.ssh/known_hosts` when it doesn't say.
    package static func knownHostsFile(_ alias: String, shell: BoxShell, home: String = NSHomeDirectory()) async -> String {
        let address = BoxAddress(alias)
        let said = await BoxShell.process(shell.ssh, ["-G"] + (address?.options ?? []) + ["--", address?.host ?? alias], limit: shell.reach)
        return knownHostsFile(config: said.ok ? said.output : "", home: home)
    }

    package static func knownHostsFile(config: String, home: String) -> String {
        let fallback = home + "/.ssh/known_hosts"
        for line in config.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            guard words.first?.lowercased() == "userknownhostsfile", let first = words.dropFirst().first else { continue }
            if first == "/dev/null" || first.lowercased() == "none" { return fallback }
            if first.hasPrefix("~/") { return home + first.dropFirst() }
            return first.hasPrefix("/") ? first : fallback
        }
        return fallback
    }

    /// Why Trust added nothing.
    package enum Refusal: Error, Equatable, Sendable {
        /// The box shows another key than the one shown: never trusted.
        case changed
        /// ssh couldn't get a key this time.
        case unreachable
        /// The file couldn't be written.
        case unwritable(String)
    }

    /// Trust: looks again, and only when the box shows the key that was shown adds ssh's own lines
    /// (this look's, for where the alias points now) to `file` (made 0600 in a 0700 folder when new). Nil: trusted.
    package static func trust(_ offer: Offer, shell: BoxShell, file: String, keygen: String = keygen) async -> Refusal? {
        guard let now = await scan(offer.ssh, shell: shell, keygen: keygen) else { return .unreachable }
        guard Set(now.fingerprints) == Set(offer.fingerprints), keys(now.lines) == keys(offer.lines), !keys(now.lines).isEmpty else { return .changed }
        let url = URL(fileURLWithPath: file)
        let manager = FileManager.default
        do {
            let folder = url.deletingLastPathComponent()
            if !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { return .unwritable(file) }
            }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let adding = now.lines.filter { !existing.contains($0) }
            guard !adding.isEmpty else { return nil }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let lead = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try handle.write(contentsOf: Data((lead + adding.joined(separator: "\n") + "\n").utf8))
            return nil
        } catch {
            return .unwritable(file)
        }
    }
}
