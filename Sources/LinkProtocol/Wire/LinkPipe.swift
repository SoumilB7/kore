import Foundation

/// Link 1.16: rsync over KoreNet's own connections, no SSH (phase 18 §1 "Bulk"). The Mac's
/// rsync runs `kore pipe` as its remote shell; `kore pipe` asks Kore, Kore asks the box
/// (`pipe.open {argv}`), and the box checks the remote command (`PipeArgv`) and where its paths
/// lead, then answers with a ticket for one pipe session (KoreNet service "pipe") within
/// `ticketSeconds`. Box to box: the Mac gives the receiving box a ticket to expect
/// (`pipe.expect {ticket, device, path}`), then asks the sending box to copy over a pipe with it
/// (`pipe.send {ticket, device, from, to}`); the sender's remote command comes on the pipe's own
/// session with the ticket, and the receiver checks it then, its paths inside `path`.
package enum LinkPipe {
    /// The welcome's cap a box says when it serves pipes.
    package static let cap = "pipe"
    /// A ticket is spent by its session's hello within this long, once.
    package static let ticketSeconds: TimeInterval = 60
    /// Pipes a device holds at once on a box, tickets not yet spent included.
    package static let perDevice = 2
    /// The words of a remote command, and the bytes of one.
    package static let argvMax = 64
    package static let wordMax = 4096

    package static func check(_ kind: ControlKind, _ args: ControlArgs) -> LinkPolicy.Verdict {
        switch kind {
        case .pipeOpen:
            return plainArgv(args.argv) ? .allow : .deny(.invalid, "Name the remote command.")
        case .pipeExpect:
            // The sending box's remote command comes with the ticket on its pipe session, checked
            // then: its paths inside `path`, received here.
            guard plainTicket(args.ticket), plainDevice(args.device) else { return .deny(.invalid, "Name the ticket and the box.") }
            return LinkFiles.plainPath(args.path) ? .allow : .deny(.invalid, "An absolute path.")
        case .pipeSend:
            guard plainTicket(args.ticket), plainDevice(args.device) else { return .deny(.invalid, "Name the ticket and the box.") }
            guard LinkFiles.plainPath(args.from), LinkFiles.plainPath(args.to) else { return .deny(.invalid, "Two absolute paths.") }
            return .allow
        default:
            return .deny(.invalid, LinkPolicy.notTaken)
        }
    }

    static func plainArgv(_ argv: [String]?) -> Bool {
        guard let argv, !argv.isEmpty, argv.count <= argvMax else { return false }
        return argv.allSatisfy { !$0.isEmpty && $0.utf8.count <= wordMax && !$0.contains("\0") }
    }

    static func plainTicket(_ ticket: String?) -> Bool { ticket.flatMap { Data(base64Encoded: $0) }?.count == 16 }

    static func plainDevice(_ device: String?) -> Bool { device.flatMap(UUID.init(uuidString:)) != nil }
}
