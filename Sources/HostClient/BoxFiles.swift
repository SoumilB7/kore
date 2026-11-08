import Foundation
import LinkProtocol

// Link 1.7 on the Mac's side: a box's folders listed and its files read, for a box window's
// explorer and the Welcome's folder browser (`LinkFiles.swift`). Nothing here runs until asked;
// nothing is kept on this Mac.

/// A folder's listing as the box gave it.
package struct BoxListing: Sendable, Equatable {
    /// The folder, as the box normalised it.
    package var path: String
    package var entries: [FileEntry]
    /// The box stopped at its cap: there's more in the folder than these.
    package var more: Bool

    package init(path: String, entries: [FileEntry], more: Bool) {
        self.path = path
        self.entries = entries
        self.more = more
    }
}

/// A file as `fs.read` found it.
package struct BoxFileRead: Sendable, Equatable {
    package var path: String
    package var kind: FileReadKind
    package var size: Int64
    package var text: String?
    package var image: Data?
    package var truncated: Bool

    package init(path: String, kind: FileReadKind, size: Int64, text: String?, image: Data?, truncated: Bool) {
        self.path = path
        self.kind = kind
        self.size = size
        self.text = text
        self.image = image
        self.truncated = truncated
    }
}

/// What lists and reads a box's files: the link, or a test's stand-in.
@MainActor
package protocol BoxFileSource: AnyObject {
    var alias: String { get }
    func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal>
    func read(_ path: String, max: Int?) async -> Result<BoxFileRead, HostRefusal>
    func makeFolder(_ path: String) async -> Result<String, HostRefusal>
}

extension HostConnection: BoxFileSource {
    package func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal> {
        let result = await files(.fsList, ControlArgs(path: path, hidden: hidden ? true : nil))
        guard result.ok, let entries = result.entries else { return .failure(refusal(result)) }
        return .success(BoxListing(path: result.path ?? path ?? "", entries: entries, more: result.more == true))
    }

    package func read(_ path: String, max: Int? = nil) async -> Result<BoxFileRead, HostRefusal> {
        let result = await files(.fsRead, ControlArgs(path: path, max: max))
        guard result.ok, let kind = result.kind else { return .failure(refusal(result)) }
        return .success(BoxFileRead(
            path: result.path ?? path, kind: kind, size: result.size ?? 0, text: result.text,
            image: result.data.flatMap { Data(base64Encoded: $0) }, truncated: result.truncated == true))
    }

    package func makeFolder(_ path: String) async -> Result<String, HostRefusal> {
        let result = await files(.fsMkdir, ControlArgs(path: path))
        guard result.ok else { return .failure(refusal(result)) }
        return .success(result.path ?? path)
    }

    /// One `fs.*` command: at once while linked, after the dial while it's connecting; a link that
    /// can't be reached says so at once rather than waiting.
    private func files(_ kind: ControlKind, _ args: ControlArgs) async -> FilesResult {
        switch phase {
        case .refused(let why): return .refused("", .unknown, why.line(alias))
        case .offline, .idle: return .refused("", .unknown, "\(alias) can't be reached")
        case .connecting, .online: break
        }
        let (result, raw) = await commandRaw { HostWire.command(id: $0, .control(kind, args)) }
        if let raw, let decoded = try? JSONDecoder().decode(FilesResult.self, from: raw) { return decoded }
        return FilesResult(id: result.id, ok: result.ok, code: result.code, message: result.message)
    }

    /// The box's words, or what's wrong in Kore's: a box from before 1.7 doesn't know the command.
    private func refusal(_ result: FilesResult) -> HostRefusal {
        if result.ok { return HostRefusal(message: "\(alias) sent nothing") }
        if result.code == .invalid, ["Unknown command.", "Not taken here."].contains(result.message) {
            return HostRefusal(message: "\(alias) needs an update to show files")
        }
        if result.code == .deniedControl { return HostRefusal(message: "Files need a grant with full control on \(alias)") }
        return HostRefusal(message: result.message ?? "\(alias) refused it")
    }
}
