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

    /// Where lines go: tests read them, or turn them off with nil.
    package static func listen(_ to: (@Sendable (String) -> Void)?) { lock.withLock { sink = to } }

    /// One event and its fields (`connect grant=laptop control=full`); fields with no value are left out.
    package static func note(_ event: String, _ fields: KeyValuePairs<String, String?> = [:]) {
        var line = event
        for (key, value) in fields {
            guard let value else { continue }
            line += " " + key + "=" + quoted(value)
        }
        let sink = lock.withLock { sink }
        sink?(line)
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
