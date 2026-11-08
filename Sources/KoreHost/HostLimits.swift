import Foundation
import LinkProtocol

/// Link 1.12: how fast a watch or act grant's client may go, the Mac's own link's numbers
/// (`LinkHost`): 20 messages a second with a burst of 40 (an upload's chunks aside), 30 commands
/// a minute, 10 sends and 10 account commands a minute, 2 history pages a second. A command past
/// a limit is answered `rate.limited`; a client far past the message rate is told
/// `bye rateLimited`. A full grant isn't limited. Nothing here runs between messages: each limit
/// is counted when one comes, against the time it came.
struct HostLimits {
    var bucket = MessageBucket(rate: 20, burst: 40)
    var commands = RateLimiter(limit: 30, per: 60)
    var sends = RateLimiter(limit: 10, per: 60)
    var accounts = RateLimiter(limit: 10, per: 60)
    var reads = RateLimiter(limit: 2, per: 1)

    enum Verdict: Equatable {
        case ok
        /// Past the message rate, and not a command: dropped.
        case drop
        /// A command (or read) past a limit: answered `rate.limited` under this id.
        case refuse(String)
        /// Far past the message rate: the link ends.
        case end
    }

    mutating func admit(_ message: LinkMessage, at now: Date) -> Verdict {
        // An upload's chunks are bounded by the upload itself (its declared size).
        if case .blobPutChunk = message { return .ok }
        switch bucket.take(at: now) {
        case .ok: break
        case .over:
            if case .cmd(let id, _) = message { return .refuse(id) }
            return .drop
        case .far: return .end
        }
        switch message {
        case .cmd(let id, let command):
            guard commands.take(at: now) else { return .refuse(id) }
            if case .send = command, !sends.take(at: now) { return .refuse(id) }
            if case .control(let kind, _) = command, kind.onAccount, !accounts.take(at: now) { return .refuse(id) }
            return .ok
        case .historyList(let id, _, _, _, _):
            return reads.take(at: now) ? .ok : .refuse("history.list:" + id)
        default:
            return .ok
        }
    }
}
