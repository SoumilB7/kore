import Darwin
import Foundation
import KoreCore

/// Who is on the other end of the agent channel, from the kernel and Kore's own records, never
/// from what the caller says: its process (`LOCAL_PEERTOKEN`), the processes above it, and
/// which of those Kore started as a chat's CLI. A chat's pass (`AgentPasses`) must name the same
/// chat the tree does.
package enum AgentCaller {
    /// What a connection's peer is, before its hello says anything.
    package struct Peer: Sendable, Equatable {
        package let pid: pid_t
        /// Its pid, its parent's, and so on up to (not including) launchd.
        package let ancestors: [pid_t]
    }

    package enum Verdict: Equatable, Sendable {
        /// Runs under the CLI started with this pass, and said it.
        case chat(pass: String)
        /// Under no chat's CLI, and with no pass.
        case external
        /// Under one chat's CLI with another pass (or none), or a pass outside its chat's tree.
        case mismatch
    }

    /// The deepest walk up the tree.
    static let depthMax = 64

    /// A connected socket's peer: the same user, its pid from its audit token, and its chain of
    /// parents (read now, while it holds the connection). Nil for another user's process.
    package static func peer(_ fd: Int32) -> Peer? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), let token = LinkIdentity.peerToken(fd) else { return nil }
        // audit_token_t's val[5] is the pid (bsm/libbsm.h's audit_token_to_pid).
        let pid = token.withUnsafeBytes { $0.load(fromByteOffset: 5 * MemoryLayout<UInt32>.size, as: UInt32.self) }
        let own = pid_t(pid)
        return Peer(pid: own, ancestors: ancestors(of: own, parent: ProcessChild.parent(of:)))
    }

    /// `pid` and the processes above it, nearest first, stopping before launchd or a loop.
    package static func ancestors(of pid: pid_t, parent: (pid_t) -> pid_t?) -> [pid_t] {
        var out: [pid_t] = []
        var next: pid_t? = pid
        while let current = next, current > 1, out.count < depthMax, !out.contains(current) {
            out.append(current)
            next = parent(current)
        }
        return out
    }

    /// The caller's chat, or external, or a refusal: the nearest CLI above it Kore started with
    /// a pass decides, and the caller's own pass has to be that one.
    package static func verdict(ancestors: [pid_t], pass: String?, clis: [String: pid_t]) -> Verdict {
        let byPid = Dictionary(clis.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        if let tree = ancestors.lazy.compactMap({ byPid[$0] }).first {
            return pass == tree ? .chat(pass: tree) : .mismatch
        }
        // A pass from outside every chat's tree: copied, or its chat is gone.
        return pass == nil || pass?.isEmpty == true ? .external : .mismatch
    }
}
