import Foundation
import KoreCore
import LinkProtocol

/// kore-host's own lines, on stderr, which systemd keeps in the journal
/// (`journalctl --user -u kore-host`): one per start and stop, connection and refusal, CLI start
/// and stop, and failed write. Grant names, chat ids, paths and reasons only: never a secret, a
/// token or anything said in a chat.
package enum HostJournal {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)? = KoreLog.isTestProcess ? nil : stderr

    private static let stderr: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    nonisolated(unsafe) private static var watchers: [UUID: @Sendable (String) -> Void] = [:]

    /// Where lines go: tests read them, or turn them off with nil.
    package static func listen(_ to: (@Sendable (String) -> Void)?) { lock.withLock { sink = to } }

    /// Lines also go to `to` until `unwatch` (tests running side by side each keep their own).
    package static func watch(_ to: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { watchers[id] = to }
        return id
    }

    package static func unwatch(_ id: UUID) { _ = lock.withLock { watchers.removeValue(forKey: id) } }

    /// One event and its fields (`connect grant=laptop control=full`); fields with no value are left out.
    package static func note(_ event: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        var line = event
        for (key, value) in fields {
            guard let value else { continue }
            line += " " + key + "=" + quoted(value)
        }
        let (sink, watching) = lock.withLock { (sink, Array(watchers.values)) }
        sink?(line)
        for watcher in watching { watcher(line) }
    }

    /// Phase 18's audit lines, tagged `audit` (`audit connect device=… route=tailnet`): connect,
    /// enroll, allow, deny, revoke, pending, node-key, denied (the command's kind only). Who and
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
        note(code == ENOSPC ? "disk full" : "write failed", ["path": url.path, "reason": String(cString: strerror(code))])
    }

    private static func quoted(_ value: String) -> String {
        let plain = !value.isEmpty && !value.contains { $0 == " " || $0 == "\"" || $0 == "=" || $0.isNewline }
        if plain { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
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
