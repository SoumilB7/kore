import Foundation

/// Every ssh (and scp, and rsync's `-e`) Kore runs to a box, built in one place: the program,
/// Kore's options for the use, the alias's own (a typed destination's user and port), then the
/// route the tailnet takes now (`SSHTailnetRoute`), then `--` and the host. The route is decided
/// afresh for each spawn, so a box whose alias names a stopped Tailscale's address is reached
/// over Kore's own tailnet as its link is (0.3.10: the sync's rsync went to the dead address
/// while the link ran on Kore's tailnet). `BoxSSHTests` keeps every caller on it.
package enum BoxSSH {
    /// The words before `--`: `program`, `options`, the alias's options, the route now. On the
    /// main actor the route comes from the status KoreNet last heard (no socket round trip).
    package static func head(_ alias: String, program: String = SSHTransport.ssh, options: [String]) -> [String] {
        [program] + options + (BoxAddress(alias)?.options ?? []) + (Self.route?(alias) ?? SSHTailnetRoute.options(for: alias))
    }

    /// The same, its route worked out off the main actor.
    package static func head(_ alias: String, program: String = SSHTransport.ssh, options: [String]) async -> [String] {
        let given = Self.route.map { $0(alias) }
        let now = if let given { given } else { await SSHTailnetRoute.options(forAlias: alias) }
        return [program] + options + (BoxAddress(alias)?.options ?? []) + now
    }

    /// Tests: the route each alias gets, in place of `SSHTailnetRoute`'s (nil: its).
    nonisolated(unsafe) package static var route: (@Sendable (String) -> [String])?

    /// The host ssh is given: the alias, or a typed destination's host (its user and port are
    /// options in `head`).
    package static func host(_ alias: String) -> String { BoxAddress(alias)?.host ?? alias }

    /// A whole ssh command line: `head`, `--`, the host, then `rest` (the remote command).
    package static func argv(_ alias: String, program: String = SSHTransport.ssh, options: [String], _ rest: [String]) async -> [String] {
        await head(alias, program: program, options: options) + ["--", host(alias)] + rest
    }
}
