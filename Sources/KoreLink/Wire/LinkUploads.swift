import CryptoKit
import Foundation

/// Files a client sends Kore (1.1): `blob.put.begin` declares one, `blob.put.chunk`s carry it in
/// order, and `blob.put.end` checks it whole (size, SHA-256, and that its bytes are what its type
/// says) and hands it back as a blob a `chat.send` may attach. Everything here is bounded: a few
/// uploads at once, a cap on bytes held, and an unfinished upload dropped after two minutes.
package struct LinkUploads: Sendable {
    package static let maxSize = 12 * 1024 * 1024
    /// The most bytes one chunk may carry (before base64).
    package static let chunkMax = 48 * 1024
    package static let maxUploads = 3
    package static let maxBytesHeld = 36 * 1024 * 1024
    package static let unfinishedFor: TimeInterval = 120

    /// What a file's first bytes show it to be.
    package enum Sniffed: Sendable, Equatable { case image, pdf, text, other }

    package struct Failure: Error, Sendable, Equatable {
        package var code: ResultCode
        package var message: String
        init(_ code: ResultCode, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    /// A whole, checked file.
    package struct File: Sendable, Equatable {
        package var name: String
        package var mime: String
        package var data: Data
        package var sniffed: Sniffed
    }

    private struct Upload: Sendable {
        var name: String
        var mime: String
        var size: Int
        var sha256: String
        var data = Data()
        var next = 0
        var started: Date
    }

    private var uploads: [String: Upload] = [:]

    package init() {}

    package var count: Int { uploads.count }

    package mutating func begin(_ uploadId: String, name: String, mime: String, size: Int, sha256: String, at now: Date = Date()) -> Failure? {
        sweep(at: now)
        guard !uploadId.isEmpty, uploadId.count <= 64, uploads[uploadId] == nil else { return Failure(.invalid, "A bad or repeated upload id.") }
        guard size > 0, size <= Self.maxSize else { return Failure(.tooLarge, "Files can be at most 12 MB.") }
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return Failure(.invalid, "A bad SHA-256.") }
        guard uploads.count < Self.maxUploads else { return Failure(.busy, "Too many uploads at once.") }
        guard uploads.values.reduce(size, { $0 + $1.size }) <= Self.maxBytesHeld else { return Failure(.busy, "Too much uploading at once.") }
        uploads[uploadId] = Upload(name: name, mime: mime.lowercased(), size: size, sha256: sha256.lowercased(), started: now)
        return nil
    }

    /// A chunk out of order, too big, or past the declared size ends the upload.
    package mutating func chunk(_ uploadId: String, index: Int, base64: String, at now: Date = Date()) -> Failure? {
        sweep(at: now)
        guard var upload = uploads[uploadId] else { return Failure(.goneBlob, "No such upload (it may have expired).") }
        guard index == upload.next, let bytes = Data(base64Encoded: base64), bytes.count <= Self.chunkMax else {
            uploads[uploadId] = nil
            return Failure(.invalid, "A chunk out of order or malformed.")
        }
        guard upload.data.count + bytes.count <= upload.size else {
            uploads[uploadId] = nil
            return Failure(.tooLarge, "More bytes than the upload declared.")
        }
        upload.data.append(bytes)
        upload.next += 1
        uploads[uploadId] = upload
        return nil
    }

    package mutating func end(_ uploadId: String, at now: Date = Date()) -> Result<File, Failure> {
        sweep(at: now)
        guard let upload = uploads.removeValue(forKey: uploadId) else { return .failure(Failure(.goneBlob, "No such upload (it may have expired).")) }
        guard upload.data.count == upload.size else { return .failure(Failure(.invalid, "The upload ended short.")) }
        guard Self.hex(SHA256.hash(data: upload.data)) == upload.sha256 else { return .failure(Failure(.badHash, "The file's SHA-256 doesn't match.")) }
        let sniffed = Self.sniff(upload.data)
        guard Self.fits(mime: upload.mime, sniffed) else { return .failure(Failure(.badType, "The file isn't what its type says.")) }
        return .success(File(name: upload.name, mime: upload.mime, data: upload.data, sniffed: sniffed))
    }

    /// Drops uploads not finished in time.
    package mutating func sweep(at now: Date = Date()) {
        uploads = uploads.filter { now.timeIntervalSince($0.value.started) < Self.unfinishedFor }
    }

    // MARK: Checks

    /// A declared type has to match the bytes: an image is an image, a PDF a PDF, text is UTF-8.
    /// Other types may be anything (they're attached as plain files).
    package static func fits(mime: String, _ sniffed: Sniffed) -> Bool {
        if mime.hasPrefix("image/") { return sniffed == .image }
        if mime == "application/pdf" { return sniffed == .pdf }
        if mime.hasPrefix("text/") { return sniffed == .text }
        return true
    }

    package static func sniff(_ data: Data) -> Sniffed {
        let b = [UInt8](data.prefix(16))
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b.prefix(p.count)) == p }
        func ascii(_ range: Range<Int>) -> String? { b.count >= range.upperBound ? String(bytes: b[range], encoding: .ascii) : nil }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8)) || starts([0x49, 0x49, 0x2A, 0x00])
            || starts([0x4D, 0x4D, 0x00, 0x2A])
        {
            return .image
        }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return .image }
        if ascii(4..<8) == "ftyp", let brand = ascii(8..<12), ["heic", "heix", "hevc", "mif1", "msf1", "avif"].contains(brand) { return .image }
        if starts(Array("%PDF-".utf8)) { return .pdf }
        let head = data.prefix(8192)
        if !head.contains(0), String(data: data, encoding: .utf8) != nil { return .text }
        return .other
    }

    package static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// A file name safe to save under: its last part, no control characters or separators, at
    /// most 120 characters.
    package static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":" }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return trimmed.isEmpty ? "file" : String(trimmed.prefix(120))
    }
}
