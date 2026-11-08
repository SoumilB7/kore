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

@Suite("gh on the box")
struct GitHubLoginTests {
    @Test func theCodeAndPageAreReadFromGhsOutput() {
        let said = """
            ! Failed to copy one-time code to clipboard
            ! First copy your one-time code: 8811-2366
            Open this URL to continue in your web browser: https://github.com/login/device
            """
        let found = GitHubLogin.parse(said)
        #expect(found?.code == "8811-2366")
        #expect(found?.url == "https://github.com/login/device")
        #expect(GitHubLogin.parse("! First copy your one-time code: 8811-2366") == nil)
    }
}
