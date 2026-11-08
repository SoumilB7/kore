import Foundation

// Link 1.12 (`docs/link-1.4-box.md`): the box's own file operations in place of the Mac's remote
// shell (`sh -c` over SSH): a sync round's deletes and folders (`sync.apply`), a folder's carried
// files and the room left (`fs.stat`), the files under a folder (`fs.find`), and a carry's landing
// put in the box's trash (`fs.delete {landing}`). Full grants only. The welcome's `caps` say
// `fsOps2` to a full grant; a box without it is answered by the shell as before.

package enum LinkFsOps {
    /// The welcome's cap a 1.12 box says to a full grant.
    package static let cap = "fsOps2"
    /// Paths one `sync.apply` takes at most (deletes and folders together): the Mac sends more in
    /// turns, each under a frame from the client (256 KiB).
    package static let applyMax = 2000
    /// Bytes of paths the Mac puts in one `sync.apply`.
    package static let applyBytes = 160 * 1024
    /// `fs.find` lists at most this many paths, or this many bytes of them (`more` past either).
    package static let findMax = 20_000
    package static let findBytes = 768 * 1024

    /// A path inside a sync's folder: relative, each part a plain name (no empty, `.` or `..`
    /// part), no control characters. `SyncPath.valid`'s rule, which both ends of a sync keep.
    package static func plainRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= LinkFiles.pathMax else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// A name a carry gives what it lands on its way (hidden): `.kore-copy-…`, or
    /// `.<name>.kore-<8 hex>` (`LinkFiles.copyLanding`). The only names `fs.delete {landing}` takes.
    package static func isLanding(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        if name.hasPrefix(".kore-copy-") { return true }
        guard let range = name.range(of: ".kore-", options: .backwards) else { return false }
        let token = name[range.upperBound...]
        return token.count == 8 && token.allSatisfy(\.isHexDigit)
    }
}
