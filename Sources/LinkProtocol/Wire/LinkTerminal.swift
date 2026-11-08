import Foundation

// Link 1.8, terminals on a box (`docs/link-1.4-box.md`, "Terminals"): a box window's terminal
// panel runs its shells there, each on a pseudo-terminal the box keeps. Full grants only. Bytes
// cross as base64. Output is pushed: right away when the shell was quiet (a key's echo waits for
// nothing), else gathered for a frame (about 60 a second), and never while the link is behind.
// A pty outlives its link: the box keeps its last `PtyWire.scrollback` bytes and replays them
// when the client attaches again.

/// Client to box: a shell in `cwd` (inside a served folder), `cols` x `rows`. `shell`: an
/// absolute path the box lists in `/etc/shells`; absent for the user's own. Answered with a
/// `PtyResult` carrying `ptyId`.
package struct PtyOpen: Codable, Sendable, Equatable {
    package static let type = "pty.open"
    package var t = PtyOpen.type
    package var id: String
    package var cwd: String
    package var cols: Int
    package var rows: Int
    package var shell: String?

    package init(id: String, cwd: String, cols: Int, rows: Int, shell: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.shell = shell
    }
}

/// Client to box: this link shows `ptyId` again (after a drop). The box answers a `PtyResult`,
/// then sends what the shell wrote from byte `after` on: from the scrollback's start with
/// `reset` when that's older than what it kept (or `after` is absent).
package struct PtyAttach: Codable, Sendable, Equatable {
    package static let type = "pty.attach"
    package var t = PtyAttach.type
    package var id: String
    package var ptyId: String
    package var after: Int64?
    package var cols: Int?
    package var rows: Int?

    package init(id: String, ptyId: String, after: Int64?, cols: Int? = nil, rows: Int? = nil) {
        self.id = id
        self.ptyId = ptyId
        self.after = after
        self.cols = cols
        self.rows = rows
    }
}

/// Client to box: keys and pastes, as typed. No answer.
package struct PtyInput: Codable, Sendable, Equatable {
    package static let type = "pty.input"
    package var t = PtyInput.type
    package var ptyId: String
    package var data: String

    package init(ptyId: String, data: Data) {
        self.ptyId = ptyId
        self.data = data.base64EncodedString()
    }

    package var bytes: Data? { Data(base64Encoded: data) }
}

/// Client to box: the view's new size. No answer.
package struct PtyResize: Codable, Sendable, Equatable {
    package static let type = "pty.resize"
    package var t = PtyResize.type
    package var ptyId: String
    package var cols: Int
    package var rows: Int

    package init(ptyId: String, cols: Int, rows: Int) {
        self.ptyId = ptyId
        self.cols = cols
        self.rows = rows
    }
}

/// Client to box: the tab closed. The shell gets SIGHUP and the pty is gone. No answer.
package struct PtyClose: Codable, Sendable, Equatable {
    package static let type = "pty.close"
    package var t = PtyClose.type
    package var ptyId: String

    package init(ptyId: String) { self.ptyId = ptyId }
}

/// Box to client: `pty.open`'s or `pty.attach`'s answer. `shell`: its name ("bash"); `exited`:
/// the shell already ended with this code (attach); `gone`: the box has no such pty.
package struct PtyResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    package var ptyId: String?
    package var shell: String?
    package var exited: Int32?
    package var gone: Bool?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, ptyId: String? = nil, shell: String? = nil, exited: Int32? = nil,
        gone: Bool? = nil
    ) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.ptyId = ptyId
        self.shell = shell
        self.exited = exited
        self.gone = gone
    }

    package static func refused(_ id: String, _ code: ResultCode, _ message: String, gone: Bool? = nil) -> PtyResult {
        PtyResult(id: id, ok: false, code: code, message: message, gone: gone)
    }
}

/// Box to client: what the shell wrote. `seq`: how many bytes it wrote before these, so the
/// client knows where it stands; `reset`: start the screen afresh, then these.
package struct PtyOutput: Codable, Sendable, Equatable {
    package static let type = "pty.output"
    package var t = PtyOutput.type
    package var ptyId: String
    package var seq: Int64
    package var data: String
    package var reset: Bool?

    package init(ptyId: String, seq: Int64, data: Data, reset: Bool = false) {
        self.ptyId = ptyId
        self.seq = seq
        self.data = data.base64EncodedString()
        self.reset = reset ? true : nil
    }

    package var bytes: Data? { Data(base64Encoded: data) }
}

/// Box to client: the shell ended, with its exit code (128 + the signal when one ended it).
package struct PtyExit: Codable, Sendable, Equatable {
    package static let type = "pty.exit"
    package var t = PtyExit.type
    package var ptyId: String
    package var code: Int32

    package init(ptyId: String, code: Int32) {
        self.ptyId = ptyId
        self.code = code
    }
}

package enum PtyWire {
    /// Live ptys one grant may hold.
    package static let maxPerGrant = 8
    /// What the box keeps of each pty's output for a client attaching again.
    package static let scrollback = 256 * 1024
    /// Output gathered for at most this long before it goes (about 60 frames a second).
    package static let coalesce: TimeInterval = 1.0 / 60
    /// The most one `pty.output` carries (before base64).
    package static let chunkMax = 96 * 1024
    /// The most one `pty.input` carries (before base64).
    package static let inputMax = 64 * 1024
    /// A shell with no client this long is hung up.
    package static let detachedLife: TimeInterval = 24 * 60 * 60
    /// The largest window either way.
    package static let sizeMax = 4000

    package static func validSize(_ cols: Int, _ rows: Int) -> Bool { (1...sizeMax).contains(cols) && (1...sizeMax).contains(rows) }
}
