import Foundation
import Testing

@testable import KoreHost
@testable import LinkProtocol

@Suite("Box grants")
struct GrantTests {
    @Test func allowWritesAPrivateGrantAndRevokeRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kh-grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GrantStore(folder)
        let grant = try store.allow("laptop", control: .full, socket: URL(fileURLWithPath: "/tmp/x.sock"))
        #expect(Data(base64Encoded: grant.secret)?.count == 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("laptop.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect(store.load("laptop") == grant)
        #expect(store.all().map(\.name) == ["laptop"])
        #expect(store.revoke("laptop"))
        #expect(store.load("laptop") == nil)
        #expect(throws: GrantError.self) { try store.allow("../x", control: .act, socket: URL(fileURLWithPath: "/tmp/x.sock")) }
    }
}
