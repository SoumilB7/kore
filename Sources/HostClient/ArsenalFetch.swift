import Foundation
import KoreCore
import LinkProtocol

/// `file.fetch` and an ask's reply file (the owner, 2026-11-17): one file copied from a folder a
/// Kore window has open, on this Mac or a box, into the asker's `.kore/inbox/`, through the carry
/// engine (`FileCarry`), as Paste carries one. Copies only, `cap` at most, never a path that looks
/// like a secret. A file on another device than the asker's (box to Mac, Mac to box, box to box)
/// needs Act device (the owner, 2026-11-20): `acrossDevices`.
package enum ArsenalFetch {
    package static let cap: Int64 = 50 * 1024 * 1024
    /// Inside the asker's folder.
    package static let inbox = ".kore/inbox"

    package enum Refusal: Error, Equatable, Sendable {
        case secret(String)
        case outside(String, device: String)
        case otherDevice
        case noDevice(String)
        case missing(String)
        case folder(String)
        case tooBig(String, bytes: Int64)
        case failed(String)

        /// What the asker's line and the model both read, after "Not fetched: ".
        package var line: String {
            switch self {
            case .secret(let name): "\(name) looks like a secret"
            case .outside(let path, let device): "\(path) is outside \(device)'s open folders"
            case .otherDevice: "a file on another device needs Arsenal's Act device tier"
            case .noDevice(let name): "no open box is named \(name)"
            case .missing(let path): "\(path) isn't there"
            case .folder(let path): "\(path) is a folder: fetch takes one file"
            case .tooBig(let name, let bytes): "\(name) is \(bytes / 1_048_576) MB: \(ArsenalFetch.cap / 1_048_576) MB at most"
            case .failed(let why): why
            }
        }
    }

    /// Looks like a secret: any part of the path is a `.env*` file, a key (`*.pem`, `*.key`,
    /// `id_*`), `credentials*`, `.netrc`, a keychain, or inside `.ssh/`, `.aws/`, `.gnupg/` or a
    /// Keychains folder.
    package static func secret(_ path: String) -> Bool {
        for part in path.split(separator: "/").map({ $0.lowercased() }) {
            if part.hasPrefix(".env") || part.hasPrefix("credentials") || part.hasPrefix("id_") || part == ".netrc" { return true }
            if part.hasSuffix(".pem") || part.hasSuffix(".key") || part.hasSuffix(".keychain") || part.hasSuffix(".keychain-db") { return true }
            if [".ssh", ".aws", ".gnupg", "keychains"].contains(part) { return true }
        }
        return false
    }

    /// A path with `.` and `..` worked out, as text: a box's (its own checks keep a copy inside
    /// the folders it serves).
    package static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty, parts.last != "~" { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }

    /// This Mac's path with its links followed (`realpath`).
    package static func real(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// What `given` names: `device:path` on the box of that name (`names` maps a box's shown name
    /// and its alias to its alias), else a path on the asker's device, under `base` when relative.
    package static func place(_ given: String, base: FilePlace, names: [String: String]) -> Result<FilePlace, Refusal> {
        let given = given.trimmingCharacters(in: .whitespaces)
        if let colon = given.firstIndex(of: ":"), !given[..<colon].contains("/"), given.index(after: colon) < given.endIndex {
            let device = String(given[..<colon])
            let path = String(given[given.index(after: colon)...])
            if ["mac", "this mac", "localhost"].contains(device.lowercased()) { return .success(.mac(path)) }
            guard let alias = names[device] ?? names[device.lowercased()] else { return .failure(.noDevice(device)) }
            return .success(.box(alias: alias, path: path))
        }
        if given.hasPrefix("/") || given.hasPrefix("~") { return .success(base.with(given)) }
        return .success(base.child(given))
    }

    /// Copies `source` into `inbox` (made if it isn't there), under its own name or "name 2" when
    /// that's taken. `roots`: the open folders on the source's device; it has to be in one, after
    /// its links are followed on this Mac. `boxes`: each box it reaches, by alias. Answers with
    /// where the copy landed. `acrossDevices`: the source may be on another device than the inbox.
    @MainActor
    package static func run(
        _ source: FilePlace, roots: [String], into inbox: FilePlace, boxes: [String: CarryBox], acrossDevices: Bool = false
    ) async -> Result<FilePlace, Refusal> {
        let shown = source.path
        if secret(shown) { return .failure(.secret(source.name)) }
        if source.alias != inbox.alias, !acrossDevices { return .failure(.otherDevice) }
        let path: String
        switch source {
        case .mac(let given):
            path = real(given)
            guard roots.map(real).contains(where: { LinkFiles.inside(path, $0) }) else { return .failure(.outside(shown, device: source.device)) }
        case .box(_, let given):
            path = normalized(given)
            guard roots.map(normalized).contains(where: { LinkFiles.inside(path, $0) }) else { return .failure(.outside(shown, device: source.device)) }
        }
        let place = source.with(path)
        if secret(path) { return .failure(.secret(place.name)) }
        let count: CarryCount?
        switch place {
        case .mac(let path): count = CarryCount.mac(path)
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return .failure(.failed("\(source.device) can't be reached now")) }
            count = try? await box.files.count(path).get()
        }
        guard let count else { return .failure(.missing(shown)) }
        if count.dir { return .failure(.folder(shown)) }
        if count.bytes > cap { return .failure(.tooBig(place.name, bytes: count.bytes)) }
        let taken = await ready(inbox, boxes: boxes)
        let name = CopyNames.free(place.name, duplicate: false) { taken.contains($0.lowercased()) }
        let carry = FileCarry(items: [CarryItem(source: place, name: name)], into: inbox, move: false, boxes: boxes)
        let outcome = await carry.run()
        if let failure = outcome.failure { return .failure(.failed(failure)) }
        return .success(outcome.landed.first ?? inbox.child(name))
    }

    /// The inbox made, with `.kore` above it; the names it holds, lowercased.
    @MainActor
    private static func ready(_ inbox: FilePlace, boxes: [String: CarryBox]) async -> Set<String> {
        switch inbox {
        case .mac(let path):
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return Set(((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { $0.lowercased() })
        case .box(let alias, let path):
            guard let files = boxes[alias]?.files else { return [] }
            _ = await files.create(inbox.parent.path, folder: true)
            _ = await files.create(path, folder: true)
            guard case .success(let listing) = await files.list(path, hidden: true) else { return [] }
            return Set(listing.entries.map { $0.name.lowercased() })
        }
    }
}
