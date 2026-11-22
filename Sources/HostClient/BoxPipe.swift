import Foundation
import KoreNet
import LinkProtocol
import Tailnet

/// rsync with a box over KoreNet, no SSH (phase 18 §1 "Bulk"). The owner's rule (2026-11-24):
/// while a box's link is on KoreNet, every copy, move, sync and transfer goes over a pipe, even
/// where SSH would work; SSH only when KoreNet is off or the box has no kore-host that serves
/// pipes. Decided at each rsync's spawn (`SyncBox.rsyncOptions`): the link as it is then.
///
/// One spawn, one broker (`PipeBroker`): rsync's `-e` is `kore pipe` with the broker's socket and
/// token. When rsync runs it, the broker asks the box over the link (`pipe.open` with rsync's
/// remote command, checked there), dials the node the link is on (service "pipe"), presents the
/// ticket and hands the ready session to `kore pipe`, which moves the bytes itself.
@MainActor
package enum BoxPipe {
    /// Kore.app's `kore` (Contents/Helpers), or the dev build's `kore-command` beside this
    /// executable; `KORE_PIPE_HELPER` names another (tests).
    package static var helper: URL? = locate()
    /// Where the brokers' sockets go: this user's own temporary folder.
    package static var directory = FileManager.default.temporaryDirectory.appendingPathComponent("kore-pipes", isDirectory: true)

    /// Whether a copy with this box goes over a pipe now.
    package static func usable(_ connection: HostConnection) -> Bool {
        connection.isOnline && connection.route == .net && connection.caps.contains(LinkPipe.cap) && helper != nil
    }

    /// Why a box reached only over KoreNet can't copy, once its link has said what it serves.
    package static func missing(_ connection: HostConnection) -> String? {
        guard connection.isOnline, !connection.caps.contains(LinkPipe.cap) else { return nil }
        return "\(NodeNames.name(connection.alias)) can't copy without SSH yet · update kore-host there, and rsync to 3.2.5 or newer"
    }

    /// rsync's `-e` for one spawn over a pipe, its broker waiting (or the helper saying there's none to be
    /// had: never SSH then); nil: the link isn't on KoreNet (SSH, if any).
    package static func eCommand(_ connection: HostConnection) -> String? {
        guard usable(connection), let helper else { return nil }
        guard let dial = connection.pipeDial else { return PipeBroker.noPipe(helper: helper.path) }
        let alias = connection.alias
        let broker: PipeBroker
        do {
            broker = try PipeBroker(directory: directory) { [weak connection] words throws(PipeHandshake.Failure) in
                let ticket = try Self.ticket(connection, words)
                let opened: NetTransport.Opened
                do {
                    opened = try dial()
                } catch {
                    throw .closed("\(NodeNames.name(alias)) can't be reached on KoreNet: \(error)")
                }
                let session = NetSession(fd: opened.fd, role: .client(opened.setup))
                try PipeHandshake.open(session, ticket: ticket, within: 20)
                guard case .established(let peer) = session.state else { throw .closed("\(NodeNames.name(alias)) went") }
                return (session, peer)
            }
        } catch {
            HostLog.note(alias, "pipe", "no socket for it: \(error)")
            return PipeBroker.noPipe(helper: helper.path)
        }
        broker.start()
        HostLog.note(alias, "pipe", "rsync over KoreNet")
        return broker.eCommand(helper: helper.path)
    }

    /// The link's `pipe.open`, waited for on the broker's own thread (never a Swift task's).
    nonisolated static func ticket(_ connection: HostConnection?, _ words: [String]) throws(PipeHandshake.Failure) -> Data {
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            answer.result = await connection?.pipeOpen(words)
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { throw .timedOut }
        switch answer.result {
        case .success(let ticket)?: return ticket
        case .failure(let refusal)?: throw .closed(refusal.message)
        case nil: throw .closed("the box's link went")
        }
    }

    private final class Answer: @unchecked Sendable {
        var result: Result<Data, HostRefusal>?
    }

    static func locate(bundle: URL = Bundle.main.bundleURL, executable: URL? = Bundle.main.executableURL) -> URL? {
        let files = FileManager.default
        if let set = ProcessInfo.processInfo.environment["KORE_PIPE_HELPER"], files.isExecutableFile(atPath: set) { return URL(fileURLWithPath: set) }
        let inApp = bundle.appendingPathComponent("Contents/Helpers/kore")
        if files.isExecutableFile(atPath: inApp.path) { return inApp }
        let beside = executable?.deletingLastPathComponent().appendingPathComponent("kore-command")
        if let beside, files.isExecutableFile(atPath: beside.path) { return beside }
        return nil
    }
}
