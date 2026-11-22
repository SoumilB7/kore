import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet

/// Box to box over a pipe (phase 18 §1 "Box↔box direct", link 1.16 `pipe.send`): the owner Mac
/// has given the other box a ticket to expect (`pipe.expect`); this box runs rsync from `from`
/// to the other's `to`, its remote shell `kore-host pipe`, which asks this daemon (a broker of
/// its own) for a pipe session to that box: dialled over the tailnet as this box, the ticket and
/// the command on it, its descriptor handed over. The answer, once rsync ends, carries its status
/// (0: copied). The Mac's staged route stays its fallback.
extension HostDaemon {
    /// The rsync options a box-to-box copy may ask for, beside the ones it always has.
    static let sendOptions: Set<String> = ["--delete", "--relative", "--mkpath", "--checksum", "--compress", "--whole-file"]

    func pipeSend(_ args: ControlArgs, id: String, from client: LinkClient) {
        func refuse(_ code: ResultCode, _ message: String) { client.sendRaw(StreamWire.encode(FilesResult.refused(id, code, message))) }
        guard let net, let tailnet = net.tailnet, let me = net.selfNode, let rsync = pipes.rsync else {
            return refuse(.invalid, "This box isn't on KoreNet, or has no rsync to send with.")
        }
        guard let to = args.device.flatMap(UUID.init(uuidString:)), let ticket = args.ticket.flatMap({ Data(base64Encoded: $0) }),
              let from = args.from, let dest = args.to
        else { return refuse(.invalid, "Name the ticket, the box and both paths.") }
        guard let record = try? devices.book.record(to), record.kind == .box else { return refuse(.goneFile, "This box doesn't know that one.") }
        guard case .success = HostFiles(home: HostPaths.home().path, served: config.folders).place(from, .homeOrServed) else {
            return refuse(.deniedPath, "Outside your home and the folders this box serves.")
        }
        let extra = (args.argv ?? []).filter(Self.sendOptions.contains)
        let identity = net.identity
        let book = devices.book
        let local = NetLocal(device: identity.device, kind: .box, nodeKey: me.publicKey, signer: identity.signer)
        let owner = me.owner
        let broker: PipeBroker
        do {
            broker = try PipeBroker(directory: paths.runtime.appendingPathComponent("pipes")) { words throws(PipeHandshake.Failure) in
                let (fd, facts) = try Self.dial(record, tailnet: tailnet)
                var setup = NetSession.Client(local: local, route: .tailnet, peer: facts, book: book, server: to, service: "pipe")
                setup.ownUser = owner
                let session = NetSession(fd: fd, role: .client(setup))
                try PipeHandshake.open(session, ticket: ticket, argv: words, within: 20)
                guard case .established(let peer) = session.state else { throw .closed("the other box went") }
                return (session, peer)
            }
        } catch {
            return refuse(.invalid, "Couldn't make the pipe's socket: \(error)")
        }
        broker.start()
        let argv = [rsync, "-a", "--partial", "--timeout=60"] + extra + ["-e", broker.eCommand(helper: HostService.executable()), from, record.name + ":" + dest]
        let who = to.uuidString.lowercased()
        Task { [weak client] in
            let (status, said) = await HostPipeProcess.run(argv)
            broker.close()
            HostJournal.note("pipe send", ["to": who, "status": String(status), "said": status == 0 ? nil : said])
            var done = FilesResult(id: id, ok: status == 0, code: status == 0 ? nil : .invalid, message: status == 0 ? nil : said.isEmpty ? "rsync ended with \(status)" : said)
            done.status = Int(status)
            client?.sendRaw(StreamWire.encode(done))
        }
    }

    /// The other box's node as the tailnet has it now: online, one of its known keys.
    nonisolated static func dial(_ record: DeviceRecord, tailnet: any Tailnet) throws(PipeHandshake.Failure) -> (Int32, NetPeerFacts) {
        do {
            let status = try tailnet.status()
            let nodes = status.peers.filter { record.nodeKeys.contains($0.publicKey) && $0.online }
            var last: (any Error)?
            for node in nodes {
                guard let address = node.tailscaleIPs.first else { continue }
                do {
                    let who = try tailnet.whois(address)
                    return (try tailnet.dial(address, port: NetListener.port), HostNet.facts(who))
                } catch {
                    last = error
                }
            }
            throw last ?? TailnetError.sidecar("\(record.name) is offline")
        } catch {
            throw .closed("\(record.name) can't be reached on KoreNet: \(error)")
        }
    }
}

/// A process run to its end without holding a thread: its status and its stderr's last words.
enum HostPipeProcess {
    static func run(_ argv: [String]) async -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let said = SaidTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { said.add(chunk) }
        }
        let status: Int32 = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(returning: 127)
            }
        }
        errors.fileHandleForReading.readabilityHandler = nil
        return (status, said.text)
    }
}

/// The last words a process said on stderr, kept small however much it says.
final class SaidTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func add(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 2048 { data = data.suffix(1024) }
        }
    }

    var text: String { lock.withLock { String(decoding: data.suffix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
}
