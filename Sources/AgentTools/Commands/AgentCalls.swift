import Foundation

/// Why a `kore` command got no data from Kore.
package enum AgentFailure: Error {
    /// No socket: Kore isn't running, or agent control is off.
    case unreachable
    /// Something else is at the socket. Nothing was said to it.
    case notKore
    /// Kore said `bye`, or a command failed: its code and words.
    case refused(code: String, message: String)
    case closed
    /// Nothing came within the read's `timeout`.
    case timedOut
}

/// What `kore`'s commands (`Reads`, `Own`, `Drive`) run on: the Mac's agent socket (`kore` in
/// Kore.app), or a box's (`kore` on a box, through kore-host to the Mac). The same commands,
/// tiers and words either way.
package protocol AgentCalls: AnyObject {
    /// One command's data, or why not.
    func run(_ command: String, _ args: AgentTools.Object) throws(AgentFailure) -> AgentTools.Object
    /// How long the next answer may take (0: for ever).
    func timeout(_ seconds: Int)
    /// The next line of a follow (`kore log -f`), nil at its end.
    func nextRaw() throws(AgentFailure) -> Data?
}

extension AgentCalls {
    func run(_ command: String) throws(AgentFailure) -> AgentTools.Object { try run(command, [:]) }
}
