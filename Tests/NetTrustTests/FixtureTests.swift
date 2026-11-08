import Foundation
@testable import KoreNet
import KoreTrust
import Testing

/// Link 2.0's contract (`Tests/Fixtures/link/v2`, written by an independent generator): the
/// binding and raise digests come out byte for byte, the fixed signatures verify, every frame
/// encodes and decodes as shown, every bad frame is refused, and control messages round-trip.
@Suite("link v2 fixtures")
struct FixtureTests {
    @Test func manifestListsEveryFile() throws {
        let manifest = try TestKit.fixture("manifest.json")
        let proto = try #require(manifest["proto"] as? [String: Int])
        #expect(proto == ["major": 2, "minor": 0])
        #expect(NetControl.version == proto["major"])
        let files = try #require(manifest["files"] as? [String: String])
        let present = try FileManager.default.contentsOfDirectory(atPath: TestKit.fixtures.path).filter { $0 != "manifest.json" }
        #expect(Set(files.values) == Set(present))
        #expect(manifest["capDomain"] as? String == KoreCapDomain)
        #expect(manifest["port"] as? Int == Int(NetListener.port))
    }

    private func binding(_ fixture: [String: Any], _ variant: String) throws -> Binding {
        let client = fixture["client"] as! [String: String], server = fixture["server"] as! [String: String]
        let v = fixture[variant] as! [String: String]
        return try Binding(
            route: v["route"]!, nonceS: Data(hex: fixture["nonceS"] as! String), nonceC: Data(hex: fixture["nonceC"] as! String),
            deviceC: UUID(uuidString: client["device"]!)!, deviceS: UUID(uuidString: server["device"]!)!,
            nodeKeyC: v["nodeKeyC"]!, nodeKeyS: v["nodeKeyS"]!)
    }

    @Test(arguments: ["tailnet", "ssh"])
    func bindingVector(_ variant: String) throws {
        let fixture = try TestKit.fixture("bind.json")
        let v = fixture[variant] as! [String: String]
        let b = try binding(fixture, variant)
        #expect(b.preimage.hex == v["preimage"])
        #expect(b.digest.hex == v["B"])
        for (side, who, sig) in [(IdentityProof.Side.client, "client", "sigC"), (.server, "server", "sigS")] {
            let keys = fixture[who] as! [String: String]
            let identity = try SoftwareIdentity(raw: Data(hex: keys["privateKey"]!))
            #expect(identity.publicKey.base64EncodedString() == keys["publicKey"])
            let record = TestKit.record(id: UUID(uuidString: keys["device"]!)!, kind: .mac, abilities: .run, key: identity)
            #expect(IdentityProof.verify(Data(base64Encoded: v[sig]!)!, binding: b, side: side, record: record) != nil)
            // And this side's own signature verifies the way Kotlin will check it.
            let own = try IdentityProof.sign(b, with: identity)
            #expect(IdentityProof.verify(own, over: b.digest, key: identity.publicKey))
        }
    }

    @Test func raiseVector() throws {
        let fixture = try TestKit.fixture("raise.json")
        let bind = try TestKit.fixture("bind.json")
        #expect(fixture["B"] as? String == (bind["tailnet"] as! [String: String])["B"])
        let nonce = Data(hex: fixture["nonce"] as! String)
        let digest = RaiseCheck.digest(binding: Data(hex: fixture["B"] as! String), nonce: nonce, chatId: fixture["chatId"] as! String, modeId: fixture["modeId"] as! String)
        #expect(digest.hex == fixture["digest"] as? String)
        let key = fixture["raiseKey"] as! [String: String]
        #expect(try SoftwareIdentity(raw: Data(hex: key["privateKey"]!)).publicKey.base64EncodedString() == key["publicKey"])
        // The node's check, with the fixture's nonce as the one it handed out.
        let check = RaiseCheck(random: { _ in nonce })
        #expect(check.challenge() == nonce)
        let outcome = check.verify(
            signature: Data(base64Encoded: fixture["sig"] as! String)!, raiseKey: Data(base64Encoded: key["publicKey"]!)!,
            binding: Data(hex: fixture["B"] as! String), nonce: nonce, chatId: fixture["chatId"] as! String, modeId: fixture["modeId"] as! String)
        #expect(outcome == .ok)
        #expect(Int(RaiseCheck.lifetime) == fixture["ttlSeconds"] as? Int)
    }

    @Test func validFramesEncodeAndDecode() throws {
        let frames = try TestKit.fixture("frames.json")
        let limits = frames["limits"] as! [String: Int]
        #expect(limits["headerSize"] == NetFrame.headerSize)
        #expect(limits["maxPayload"] == NetFrame.maxPayload)
        #expect(limits["maxMessage"] == NetFrame.maxMessage)
        #expect(limits["maxPartialStreams"] == NetFrame.maxPartialStreams)
        #expect(limits["preAuthMaxFrame"] == NetFrame.preAuthMaxFrame)
        for item in frames["valid"] as! [[String: Any]] {
            let frame = NetFrame(
                queue: NetFrame.Queue(rawValue: UInt8(item["queue"] as! Int))!, flags: .init(rawValue: UInt8(item["flags"] as! Int)),
                stream: UInt32(item["stream"] as! Int), payload: Data(hex: item["payload"] as! String))
            #expect(frame.encoded.hex == item["encoded"] as? String, "\(item["name"]!)")
            var decoder = NetFrameDecoder(preAuth: false)
            let messages = try decoder.feed(Data(hex: item["encoded"] as! String))
            #expect(messages == [NetMessage(queue: frame.queue, stream: frame.stream, payload: frame.payload)])
        }
    }

    @Test func fragmentedFramesReassembleAroundAnInteractiveOne() throws {
        let fragmented = try TestKit.fixture("frames.json")["fragmented"] as! [String: Any]
        var decoder = NetFrameDecoder(preAuth: false)
        var got: [NetMessage] = []
        for frame in fragmented["frames"] as! [String] { got += try decoder.feed(Data(hex: frame)) }
        let want = (fragmented["messages"] as! [[String: Any]]).map {
            NetMessage(queue: .init(rawValue: UInt8($0["queue"] as! Int))!, stream: UInt32($0["stream"] as! Int), payload: Data(hex: $0["payload"] as! String))
        }
        #expect(got == want)
    }

    @Test func invalidFramesAreRefused() throws {
        for item in try TestKit.fixture("frames.json")["invalid"] as! [[String: Any]] {
            var decoder = NetFrameDecoder(preAuth: item["preAuth"] as! Bool)
            let name = item["name"] as! String
            var thrown: NetFrameError?
            do {
                _ = try decoder.feed(Data(hex: item["encoded"] as! String))
            } catch let error as NetFrameError {
                thrown = error
            }
            let kind: String? = switch thrown {
            case .tooLong: "tooLong"
            case .badQueue: "badQueue"
            case .badFlags: "badFlags"
            case .control: "control"
            case .preAuth: "preAuth"
            case .queueChanged: "queueChanged"
            case .messageTooLong: "messageTooLong"
            case .tooManyStreams: "tooManyStreams"
            case nil: nil
            }
            #expect(kind == item["error"] as? String, "\(name)")
        }
    }

    @Test func controlMessagesRoundTrip() throws {
        for item in try TestKit.fixture("control.json")["messages"] as! [[String: String]] {
            let json = Data(item["json"]!.utf8)
            let message = try NetControl.decode(json)
            #expect(String(decoding: try message.encoded(), as: UTF8.self) == item["json"], "\(item["name"]!)")
        }
    }
}
