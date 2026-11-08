import Darwin
import Foundation
import KoreCore
import LinkProtocol

/// Who is on the other end of the agent channel, from the kernel and Kore's own records, never
/// from what the caller says: its process (`LOCAL_PEERTOKEN`), the processes above it, and
/// which of those Kore started as a chat's CLI. A chat's pass (`AgentPasses`) must name the same
/// chat the tree does. The kernel's token names the process that last used the socket, with its
/// pid and pid version (so a pid used again, or an `exec`, doesn't match), and is read as it is at
/// each ask: not the connecting process's, if it has handed the socket on.
package enum AgentCaller {
    /// What a connection's peer is, before its hello says anything.
    package struct Peer: Sendable, Equatable {
        package let pid: pid_t
        /// Its audit token when it connected.
        package let token: Data
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

    /// A connected socket's process: the same user, its pid and token. Nil for another user's,
    /// or one already gone.
    package static func identity(_ fd: Int32) -> (pid: pid_t, token: Data)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), let token = LinkIdentity.peerToken(fd) else { return nil }
        // audit_token_t's val[5] is the pid (bsm/libbsm.h's audit_token_to_pid).
        let pid = token.withUnsafeBytes { $0.load(fromByteOffset: 5 * MemoryLayout<UInt32>.size, as: UInt32.self) }
        return (pid_t(pid), token)
    }

    /// That process and its chain of parents, read now. Nil if the walk can't be trusted: some
    /// process on the way went while reading it, or the token changed by the end of it.
    package static func peer(_ fd: Int32, pid: pid_t, token: Data) -> Peer? {
        guard let tree = chain(of: pid, parent: parent(of:)), LinkIdentity.peerToken(fd) == token else { return nil }
        return Peer(pid: pid, token: token, ancestors: tree)
    }

    /// A process's parent, also when it's root's (Terminal's `login`, sshd): the short record is
    /// open to any user, the full one isn't. Nil if it has gone.
    package static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_status != SZOMB else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// `ancestors`, or nil if a process on the way doesn't answer: gone isn't the same as external.
    package static func chain(of pid: pid_t, parent: (pid_t) -> pid_t?) -> [pid_t]? {
        var gone = false
        let tree = ancestors(of: pid) { current in
            let up = parent(current)
            if up == nil { gone = true }
            return up
        }
        return gone ? nil : tree
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
