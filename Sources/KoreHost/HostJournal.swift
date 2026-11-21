import Foundation
import KoreCore
import LinkProtocol

/// kore-host's own lines, on stderr, which systemd keeps in the journal
/// (`journalctl --user -u kore-host`): one per start and stop, connection and refusal, CLI start
/// and stop, and failed write. Grant names, chat ids, paths and reasons only: never a secret, a
/// token or anything said in a chat.
package enum HostJournal {
    private static let lock = NSLock()
    /// stderr, until a test listens instead.
    nonisolated(unsafe) private static var toStderr = !KoreLog.isTestProcess
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    nonisolated(unsafe) private static var watchers: [UUID: @Sendable (String) -> Void] = [:]

    /// Where lines go: tests read them (each line's body, `event key=value…`), or turn them off
    /// with nil.
    package static func listen(_ to: (@Sendable (String) -> Void)?) {
        lock.withLock {
            sink = to
            toStderr = false
        }
    }

    /// Lines also go to `to` until `unwatch` (tests running side by side each keep their own).
    package static func watch(_ to: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { watchers[id] = to }
        return id
    }

    package static func unwatch(_ id: UUID) { _ = lock.withLock { watchers.removeValue(forKey: id) } }

    /// One event and its fields (`connect grant=laptop control=full`); fields with no value are
    /// left out, and a value shaped like a token is redacted. On stderr it's a whole line, as in
    /// the Mac's logs: `2026-11-08T10:00:00.000Z info connect grant=laptop control=full`.
    package static func note(_ event: String, _ fields: KeyValuePairs<String, String?> = [:], level: KoreLog.Level = .info) {
        let body = KoreLog.body(event, fields.compactMap { key, value in value.map { (key, KoreLog.redacted($0)) } })
        let (sink, toStderr, watching) = lock.withLock { (sink, toStderr, Array(watchers.values)) }
        if toStderr { FileHandle.standardError.write(Data((KoreLog.line(at: Date(), level, body) + "\n").utf8)) }
        sink?(body)
        for watcher in watching { watcher(body) }
    }

    /// Phase 18's audit lines, tagged `audit` (`audit connect device=… route=tailnet`): connect,
    /// enroll, rekey, allow, deny, revoke, pending, node-key, denied (the command's kind only). Who and
    /// what kind, never anything a message carried.
    package static func audit(_ event: String, _ fields: KeyValuePairs<String, String?> = [:]) { note("audit " + event, fields) }

    /// A thrown write error's errno (Foundation's out-of-space error as ENOSPC).
    package static func code(_ error: Error) -> Int32 {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return ENOSPC }
        return error.domain == NSPOSIXErrorDomain ? Int32(error.code) : (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) } ?? EIO
    }

    /// A write that failed: a full disk by name, else the system's reason.
    package static func writeFailed(_ url: URL, _ code: Int32) {
        note(code == ENOSPC ? "disk full" : "write failed", ["path": url.path, "reason": String(cString: strerror(code))], level: .error)
    }
}

/// The version kore-host says (`--version`, the welcome's `koreVersion`): the package's `VERSION`.
package enum HostVersion {
    package static let string: String = {
        let text = String(decoding: PackageResources.VERSION, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "unknown" : text
    }()

    /// The link version kore-host speaks.
    package static var link: String { "\(LinkProto.major).\(LinkProto.boxMinor)" }
}
