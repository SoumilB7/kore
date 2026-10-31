import Foundation
import Testing

@testable import KoreRemote

/// Every fixture in `protocol/fixtures/v1` reads as a message and writes back as the same JSON,
/// as the TypeScript schema's tests check on their side.
@Suite("protocol fixtures")
struct FixtureTests {
    struct Fixture: Decodable {
        let file: String
        let t: String
        let future: Bool
    }

    struct Manifest: Decodable { let fixtures: [Fixture] }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("protocol/fixtures/v1")

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    @Test func coversEveryMessageType() throws {
        let covered = Set(try Self.manifest().fixtures.filter { !$0.future }.map(\.t))
        #expect(covered == WireMessage.types)
    }

    @Test(arguments: try FixtureTests.manifest().fixtures.map(\.file))
    func readsAndWritesBack(_ file: String) throws {
        let fixture = try #require(try Self.manifest().fixtures.first { $0.file == file })
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(file))
        let envelope = try Envelope.decode(data)
        #expect(envelope.message.type == fixture.t)
        guard !fixture.future else { return }
        let written = try JSONSerialization.jsonObject(with: try envelope.encoded()) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        #expect(written == original, "\(file) wrote back differently")
    }

    @Test func readsANewerHostsValuesAsUnknown() throws {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("future.unknown-values.json"))
        guard case .delta(_, _, let chats, _) = try Envelope.decode(data).message, let chat = chats?.first else {
            Issue.record("not a delta with a chat")
            return
        }
        #expect(chat.state == .unknown)
        #expect(chat.cards.first?.kind == .unknown)
        #expect(chat.cards.first?.actions.first?.id == .unknown)
        #expect(chat.cards.first?.actions.first?.style == .unknown)
    }

    @Test func refusesAMessageOfNoKnownType() {
        #expect(throws: (any Error).self) { try Envelope.decode(Data(#"{"t":"launch.missiles"}"#.utf8)) }
    }
}
