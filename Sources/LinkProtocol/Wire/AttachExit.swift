/// How `kore-host attach` ends, as its exit status: what the Mac reads through ssh's own, which is
/// 255 for ssh's failures and 126 or 127 from the box's shell when kore-host isn't there to run.
package enum AttachExit: Int32, Sendable, CaseIterable {
    /// The link ended (either side closed it).
    case ended = 0
    /// A frame that couldn't be read, or one over the limit.
    case broken = 1
    case usage = 2
    /// No daemon listens on the socket: the service is stopped.
    case notRunning = 3
    /// No grant by that name on this box.
    case noGrant = 4
    /// No runtime folder for the socket (no login session, no linger).
    case noRuntime = 5

    /// ssh's own failure: the box couldn't be reached or refused the login.
    package static let sshFailed: Int32 = 255
    /// The box's shell: a command it found but couldn't run (another CPU's binary), or none.
    package static let cantRun: Int32 = 126
    package static let notFound: Int32 = 127
}
