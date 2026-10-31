import Foundation
import Testing

@testable import KoreRemote

/// Kore's own derivations, message bytes, preface and padding against `protocol/vectors/kore-v1.json`
/// (made independently, as the phone's side checks the same file).
@Suite("kore vectors")
struct KoreVectorTests {
    nonisolated(unsafe) static let file: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/vectors/kore-v1.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    func string(_ path: String...) -> String {
        var node: Any? = Self.file
        for key in path { node = (node as? [String: Any])?[key] }
        return node as? String ?? ""
    }

    @Test func hkdfLabels() throws {
        let rows = try #require(Self.file["hkdf"] as? [[String: Any]])
        for row in rows {
            let ikm = Data(hexString: row["ikm"] as! String)!
            let length = row["length"] as? Int ?? 32
            #expect(KoreKeys.derive(ikm, row["label"] as! String, count: length).hexString == row["out"] as! String)
        }
    }

    @Test func pairingCode() {
        #expect(KoreKeys.code(Data(hexString: string("code", "handshakeHash"))!) == string("code", "code"))
    }

    @Test func prologuesAndPrefaces() {
        #expect(KoreKeys.prologue(kind: .pair).hexString == string("prologue", "pair"))
        #expect(KoreKeys.prologue(kind: .link).hexString == string("prologue", "link"))
        #expect(Preface(kind: .pair).bytes.hexString == string("preface", "pair"))
        #expect(Preface(kind: .link).bytes.hexString == string("preface", "link"))
        #expect(Preface.unsupportedHint.hexString == string("preface", "unsupportedHint"))
        #expect(Preface.hello(build: 7).hexString == string("hello", "payload"))
    }

    @Test func signedMessages() {
        let h = Data(hexString: string("messages", "pair", "handshakeHash"))!
        #expect(KoreKeys.pairMessage(h).hexString == string("messages", "pair", "bytes"))
        let nonce = Data(hexString: string("messages", "stepUp", "nonce"))!
        #expect(KoreKeys.stepUpMessage(h, nonce: nonce).hexString == string("messages", "stepUp", "bytes"))
        let digest = Data(hexString: string("messages", "approve", "digest"))!
        #expect(
            KoreKeys.approveMessage(h, cardId: string("messages", "approve", "cardId"), digest: digest, action: string("messages", "approve", "action"))
                .hexString == string("messages", "approve", "bytes"))
    }

    @Test func padding() throws {
        let rows = try #require(Self.file["padding"] as? [[String: Any]])
        for row in rows {
            let record = Record(Record.Kind(rawValue: UInt8(row["kind"] as! Int))!, Data(hexString: row["body"] as! String)!)
            let padded = try record.padded()
            if let expected = row["padded"] as? String { #expect(padded.hexString == expected) }
            if let size = row["size"] as? Int { #expect(padded.count == size) }
            #expect(try Record(padded: padded) == record)
        }
    }
}

extension KoreVectorTests {
    @Test func relayDerivations() {
        let host = Data(hexString: string("relay", "hostToken"))!
        #expect(KoreKeys.mailbox(hostToken: host).hexString == string("relay", "mailbox"))
        let token = Data(hexString: string("relay", "tokenHash", "token"))!
        #expect(KoreKeys.tokenHash(token).hexString == string("relay", "tokenHash", "sha256"))
        let s = Data((0..<32).map { UInt8($0) })
        #expect(KoreKeys.relayPairToken(s) == token)
    }
}
