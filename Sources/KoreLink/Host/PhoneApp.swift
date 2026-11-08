import Foundation

/// The phone app this Mac offers its phones over KoreNet (1.13, phase 18 "Mac copy"): the three
/// files of a phone release, `SHA256SUMS`, `SHA256SUMS.sig` and `kore.apk`, kept in
/// `~/Library/Application Support/Kore/phone-app/` (android/scripts/offer-to-phone.sh puts a build
/// there). The Mac only serves them; the phone checks the signature, the hash and the signer.
package enum PhoneApp {
    /// How much one `blob.chunk` carries.
    package static let pieceSize = 512 * 1024

    /// Set only by tests (before any phone asks).
    nonisolated(unsafe) package static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kore", isDirectory: true).appendingPathComponent("phone-app", isDirectory: true)

    /// The file for a part the wire names; anything else is no part.
    package static func file(_ part: String) -> String? {
        switch part {
        case "sums": "SHA256SUMS"
        case "sig": "SHA256SUMS.sig"
        case "apk": "kore.apk"
        default: nil
        }
    }

    package static func mime(_ part: String) -> String {
        part == "apk" ? "application/vnd.android.package-archive" : "application/octet-stream"
    }

    /// `part` from `offset`, at most [pieceSize]; nil when the Mac has no such file (or the part
    /// isn't one). Read through a handle: an APK is never loaded whole for one piece.
    package static func piece(_ part: String, from offset: Int) -> (offset: Int, total: Int, data: Data)? {
        guard let name = file(part) else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = min(max(offset, 0), size)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
        let data = (try? handle.read(upToCount: min(pieceSize, size - start))) ?? Data()
        return (start, size, data)
    }
}
