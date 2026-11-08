import Foundation
import Testing
import KoreTrust

/// The book as often-asking readers see it: one read per change, the last good one on a bad read.
@Suite("device book cache")
struct DeviceBookCacheTests {
    @Test func readsAgainOnlyWhenTheFileChangesAndKeepsTheLastGoodRead() throws {
        let folder = try TestKit.scratch("cache")
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = DeviceBook(url: folder.appendingPathComponent("devices.json"))
        let cache = DeviceBookCache(book)
        #expect(cache.read() == .empty)
        let phone = TestKit.record(kind: .phone, abilities: [.read, .ask], key: SoftwareIdentity())
        try book.update { $0 = [phone] }
        #expect(cache.read().devices == [phone])
        // Unreadable now: the last good read stands.
        try PrivateFile.write(Data("{".utf8), to: book.url)
        #expect(cache.read().devices == [phone])
        // Readable and without it: gone.
        try PrivateFile.write(try TrustJSON.encoder().encode(DeviceBook.Contents(rev: 9, devices: [])), to: book.url)
        #expect(cache.read() == DeviceBook.Contents(rev: 9, devices: []))
        // Gone altogether: empty.
        try FileManager.default.removeItem(at: book.url)
        #expect(cache.read() == .empty)
    }
}
