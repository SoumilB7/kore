import Foundation

/// The reconnect card's line under "mybox disconnected" (`BoxOfflineDialog`): which way it's
/// trying now, and once it has given up, what it tried; never a spinner with no end.
///
/// - "Reconnecting over Kore's tailnet · mybox-kore" / "Reconnecting over Tailscale · mybox"
/// - "Reconnecting over SSH" / "Reconnecting over SSH · via 100.113.194.5"
/// - "Reconnecting… · tried the tailnet and SSH" (between tries)
/// - "Can't reach mybox · tried the tailnet and SSH" (given up: Try again, or it dials by itself
///   on a wake, a network change or the box coming online)
package enum ReconnectWords {
    package static func status(name: String, trying: HostRoute?, node: String?, via: String?, tried: [String], gaveUp: Bool, sshNoRoute: Bool = false) -> String {
        // SSH that can't go isn't counted as tried: the line says why instead.
        let list = triedList(sshNoRoute ? tried.filter { $0 != "ssh" } : tried)
        let why = sshNoRoute ? " · SSH needs Tailscale on this Mac" : ""
        if gaveUp { return "Can't reach \(name)" + (list.map { " · tried " + $0 } ?? "") + why }
        if sshNoRoute, trying != .net { return "Reconnecting…" + (list.map { " · tried " + $0 } ?? "") + why }
        switch trying {
        case .net?:
            guard let node else { return "Reconnecting over the tailnet" }
            return "Reconnecting over " + (node.lowercased().contains("-kore") ? "Kore's tailnet" : "Tailscale") + " · " + node
        case .ssh?:
            return "Reconnecting over SSH" + (via.map { " · via " + $0 } ?? "")
        case nil:
            return "Reconnecting…" + (list.map { " · tried " + $0 } ?? "")
        }
    }

    /// "the tailnet and SSH", "SSH", nil for nothing tried yet.
    static func triedList(_ tried: [String]) -> String? {
        let words = tried.map { $0 == "net" ? "the tailnet" : "SSH" }
        switch words.count {
        case 0: return nil
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words.last!
        }
    }
}

extension HostConnection {
    /// The reconnect card's line for this link now.
    package var reconnectLine: String {
        let net = KoreNetSwitch.shared
        return ReconnectWords.status(
            name: NodeNames.name(alias), trying: trying, node: net?.dialling[alias], via: net?.sshVia[alias] ?? nil, tried: tried, gaveUp: gaveUp,
            sshNoRoute: net?.sshNoRoute.contains(alias) == true)
    }
}
