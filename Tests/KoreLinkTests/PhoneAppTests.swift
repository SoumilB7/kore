import Foundation
import Testing

@testable import KoreLink

/// The phone app a Mac offers over KoreNet (1.13 `app.get`): served in pieces from its folder, nothing else.
@Suite(.serialized) struct PhoneAppTests {
    @Test func servesEachPartInPiecesAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = PhoneApp.folder
        PhoneApp.folder = folder
        defer { PhoneApp.folder = saved }
        #expect(PhoneApp.piece("apk", from: 0) == nil)
        let apk = Data((0..<(PhoneApp.pieceSize + 100)).map { UInt8($0 % 251) })
        try apk.write(to: folder.appendingPathComponent("kore.apk"))
        try Data("# kore 0.4.0 x\n".utf8).write(to: folder.appendingPathComponent("SHA256SUMS"))
        let first = try #require(PhoneApp.piece("apk", from: 0))
        #expect(first.offset == 0 && first.total == apk.count && first.data == apk.prefix(PhoneApp.pieceSize))
        let rest = try #require(PhoneApp.piece("apk", from: PhoneApp.pieceSize))
        #expect(rest.data == apk.suffix(100))
        #expect(PhoneApp.piece("apk", from: apk.count + 5)?.data.isEmpty == true)
        #expect(PhoneApp.piece("sums", from: 0)?.data == Data("# kore 0.4.0 x\n".utf8))
        #expect(PhoneApp.piece("sig", from: 0) == nil)
        // Only the three parts: no path, no other file.
        #expect(PhoneApp.piece("../kore.apk", from: 0) == nil && PhoneApp.piece("kore.apk", from: 0) == nil)
    }
}
