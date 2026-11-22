import Foundation

/// A failed rsync, scp or ssh to a box, as one plain sentence: what the person can act on (the
/// box can't be reached, its key changed, rsync isn't there), never the tool's own text, which
/// goes to hosts.log. rsync's exit codes and ssh's 255 are read with the last thing it said.
package enum BoxCopyWords {
    package enum Why: Equatable, Sendable {
        /// The box didn't answer over SSH (timed out, no route, refused, the link closed).
        case unreachable
        /// It answered, and didn't take this Mac's SSH key.
        case keyRefused
        /// Its host key isn't the one this Mac knows.
        case hostKey
        /// rsync isn't installed there.
        case noRsync
        /// Nothing moved for the timeout's length.
        case stalled
        /// A disk filled up.
        case full
        /// A file couldn't be read or written.
        case permission
        /// Anything else: rsync's exit code.
        case other(Int32)
    }

    /// Why it stopped: what it said first, then its exit code.
    package static func why(status: Int32, said: String) -> Why {
        let text = said.lowercased()
        func has(_ any: String...) -> Bool { any.contains { text.contains($0) } }
        if has("host key verification failed", "remote host identification has changed") { return .hostKey }
        if has("permission denied (publickey", "permission denied (password", "too many authentication failures") { return .keyRefused }
        if status == 127 || has("rsync: command not found", "rsync: not found", "sh: rsync", "rsync: no such file") { return .noRsync }
        if has("no space left on device", "disk quota exceeded") { return .full }
        if status == 30 || has("timed out in data", "io timeout") { return .stalled }
        if status == 255 || [5, 10, 12, 35].contains(status)
            || has(
                "operation timed out", "connection timed out", "no route to host", "connection refused", "could not resolve hostname",
                "network is unreachable", "connection closed", "connection reset", "unexpected end of file", "connection unexpectedly closed",
                "broken pipe", "kex_exchange_identification")
        {
            return .unreachable
        }
        if has("permission denied", "operation not permitted", "read-only file system") { return .permission }
        return .other(status)
    }

    /// The sentence, about `box` (its name, as Devices shows it).
    package static func line(_ why: Why, box: String) -> String {
        switch why {
        case .unreachable: "\(box) can't be reached over SSH right now"
        case .keyRefused: "\(box) didn't accept this Mac's SSH key"
        case .hostKey: "\(box)'s host key isn't the one this Mac knows"
        case .noRsync: "rsync isn't installed on \(box)"
        case .stalled: "the link to \(box) stalled"
        case .full: "a disk is full, on \(box) or this Mac"
        case .permission: "a file couldn't be read or written, on \(box) or this Mac"
        case .other(let code): "the copy with \(box) stopped (rsync \(code))"
        }
    }

    package static func line(status: Int32, said: String, box: String) -> String { line(why(status: status, said: said), box: box) }

    /// It may go again by itself once the box is reachable: the route came back, the link did.
    package static func waitsForRoute(_ why: Why) -> Bool { why == .unreachable || why == .stalled }
}
