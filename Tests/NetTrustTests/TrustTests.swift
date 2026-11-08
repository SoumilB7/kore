import Foundation
import KoreTrust
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// The binding, identity proofs and their refusals.
@Suite("binding and proofs")
struct BindingTests {
    let client = SoftwareIdentity()
    let server = SoftwareIdentity()
    let deviceC = UUID()
    let deviceS = UUID()

    func binding(route: String = "tailnet", nonceS: Data = Data(repeating: 1, count: 32), nonceC: Data = Data(repeating: 2, count: 32),
                 deviceC: UUID? = nil, deviceS: UUID? = nil, nodeKeyC: String = "nodekey:c", nodeKeyS: String = "nodekey:s") throws -> Binding {
        try Binding(route: route, nonceS: nonceS, nonceC: nonceC, deviceC: deviceC ?? self.deviceC, deviceS: deviceS ?? self.deviceS, nodeKeyC: nodeKeyC, nodeKeyS: nodeKeyS)
    }

    @Test func signedBindingVerifiesForItsSignerOnly() throws {
        let b = try binding()
        let sig = try IdentityProof.sign(b, with: client)
        let clientRecord = TestKit.record(id: deviceC, kind: .phone, abilities: [.read, .ask], key: client)
        let peer = try #require(IdentityProof.verify(sig, binding: b, side: .client, record: clientRecord))
        #expect(peer.device == deviceC && peer.nodeKey == "nodekey:c")
        // The same signature claimed by the server side, or checked against another key, fails.
        #expect(IdentityProof.verify(sig, binding: b, side: .server, record: clientRecord) == nil)
        let impostor = TestKit.record(id: deviceC, kind: .phone, abilities: [.read], key: server)
        #expect(IdentityProof.verify(sig, binding: b, side: .client, record: impostor) == nil)
        #expect(IdentityProof.verify(Data("junk".utf8), binding: b, side: .client, record: clientRecord) == nil)
    }

    /// Each field of B, changed alone, breaks the proof (a MITM with another node key, a replayed
    /// nonce, a swapped device, another route).
    @Test(arguments: ["route", "nonceS", "nonceC", "deviceC", "deviceS", "nodeKeyC", "nodeKeyS"])
    func tamperedFieldIsRefused(_ field: String) throws {
        let good = try binding()
        let sig = try IdentityProof.sign(good, with: client)
        let other = Data(repeating: 9, count: 32)
        let tampered: Binding
        switch field {
        case "route": tampered = try binding(route: "ssh")
        case "nonceS": tampered = try binding(nonceS: other)
        case "nonceC": tampered = try binding(nonceC: other)
        case "deviceC": tampered = try binding(deviceC: UUID())
        case "deviceS": tampered = try binding(deviceS: UUID())
        case "nodeKeyC": tampered = try binding(nodeKeyC: "nodekey:mitm")
        default: tampered = try binding(nodeKeyS: "nodekey:mitm")
        }
        #expect(tampered.digest != good.digest)
        // A changed client id means the record looked up is the impostor's own id, same key.
        let record = TestKit.record(id: tampered.deviceC, kind: .phone, abilities: [.read], key: client)
        #expect(IdentityProof.verify(sig, binding: tampered, side: .client, record: record) == nil)
    }

    @Test func bindingFieldRules() throws {
        #expect(throws: TrustError.badField("route")) { try binding(route: "wifi") }
        #expect(throws: TrustError.badField("nonceS")) { try binding(nonceS: Data(count: 31)) }
        #expect(throws: TrustError.badField("nonceC")) { try binding(nonceC: Data(count: 33)) }
        #expect(throws: TrustError.badField("devices")) { try binding(deviceS: deviceC) }
        #expect(throws: TrustError.badField("nodeKey")) { try binding(nodeKeyS: "") }
    }

    /// Length prefixes keep field boundaries: moving bytes between fields changes B.
    @Test func fieldBoundariesMatter() throws {
        let a = try binding(nodeKeyC: "nodekey:ab", nodeKeyS: "c")
        let b = try binding(nodeKeyC: "nodekey:a", nodeKeyS: "bc")
        #expect(a.digest != b.digest)
    }

    @Test func boxKeyFileIsPrivateAndStable() throws {
        let folder = try TestKit.scratch("key")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("keys/identity.key")
        let first = try IdentityKeyFile.loadOrCreate(at: url)
        let again = try IdentityKeyFile.loadOrCreate(at: url)
        #expect(first.publicKey == again.publicKey)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((folderAttributes[.posixPermissions] as? Int) == 0o700)
        chmod(url.path, 0o644)
        #expect(throws: TrustError.io("identity.key is not private")) { try IdentityKeyFile.loadOrCreate(at: url) }
    }
}

/// Mode raises: single-use nonces, 60 s, the right key over the right digest.
@Suite("raise check")
struct RaiseCheckTests {
    let phone = SoftwareIdentity()
    let clock = FakeClock()
    let b = Data(repeating: 4, count: 32)

    func sign(_ nonce: Data, chat: String = "chat-1", mode: String = "auto") throws -> Data {
        try phone.sign(RaiseCheck.digest(binding: b, nonce: nonce, chatId: chat, modeId: mode))
    }

    @Test func goodSignatureOnceThenReplayRefused() throws {
        let check = RaiseCheck(clock: clock.function)
        let nonce = check.challenge()
        #expect(nonce.count == 32)
        let sig = try sign(nonce)
        #expect(check.verify(signature: sig, raiseKey: phone.publicKey, binding: b, nonce: nonce, chatId: "chat-1", modeId: "auto") == .ok)
        #expect(check.verify(signature: sig, raiseKey: phone.publicKey, binding: b, nonce: nonce, chatId: "chat-1", modeId: "auto") == .unknownNonce)
    }

    @Test func expiresAtSixtySeconds() throws {
        let check = RaiseCheck(clock: clock.function)
        let early = check.challenge()
        let late = check.challenge()
        clock.advance(59.9)
        #expect(check.verify(signature: try sign(early), raiseKey: phone.publicKey, binding: b, nonce: early, chatId: "chat-1", modeId: "auto") == .ok)
        clock.advance(0.1)
        #expect(check.verify(signature: try sign(late), raiseKey: phone.publicKey, binding: b, nonce: late, chatId: "chat-1", modeId: "auto") == .expired)
    }

    @Test func wrongDigestOrKeySpendsTheNonce() throws {
        let check = RaiseCheck(clock: clock.function)
        let nonce = check.challenge()
        let forOtherChat = try sign(nonce, chat: "chat-2")
        #expect(check.verify(signature: forOtherChat, raiseKey: phone.publicKey, binding: b, nonce: nonce, chatId: "chat-1", modeId: "auto") == .badSignature)
        #expect(check.verify(signature: try sign(nonce), raiseKey: phone.publicKey, binding: b, nonce: nonce, chatId: "chat-1", modeId: "auto") == .unknownNonce)
        let n2 = check.challenge()
        #expect(check.verify(signature: try sign(n2), raiseKey: SoftwareIdentity().publicKey, binding: b, nonce: n2, chatId: "chat-1", modeId: "auto") == .badSignature)
        let n3 = check.challenge()
        #expect(check.verify(signature: try sign(n3, mode: "bypass"), raiseKey: phone.publicKey, binding: b, nonce: n3, chatId: "chat-1", modeId: "auto") == .badSignature)
    }

    @Test func outstandingNoncesAreBounded() {
        let check = RaiseCheck(clock: clock.function)
        let first = check.challenge()
        for _ in 0..<RaiseCheck.maxOutstanding { _ = check.challenge() }
        #expect(check.verify(signature: Data(), raiseKey: phone.publicKey, binding: b, nonce: first, chatId: "c", modeId: "m") == .unknownNonce)
    }
}

/// The device book: private, atomic, rev'd, and node keys kept only after a proof.
@Suite("device book")
struct DeviceBookTests {
    let folder: URL
    let book: DeviceBook
    let mac = SoftwareIdentity()
    let phone = SoftwareIdentity()

    init() throws {
        folder = try TestKit.scratch("book")
        book = DeviceBook(url: folder.appendingPathComponent("devices.json"))
    }

    @Test func emptyBookIsRevZeroAndWritesArePrivate() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try book.read() == .empty)
        let record = TestKit.record(kind: .phone, abilities: [.read, .ask], key: phone)
        let after = try book.update { $0.append(record) }
        #expect(after.rev == 1)
        #expect(try book.record(record.id) == record)
        #expect(try book.record(nodeKey: "nodekey:aa") == record)
        let mode = try FileManager.default.attributesOfItem(atPath: book.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // No change, no new rev; a change, one more.
        #expect(try book.update { _ in }.rev == 1)
        #expect(try book.update { $0[0].name = "pixel" }.rev == 2)
        // Nothing but the book and its lock is left behind (no temp files).
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["devices.json", "devices.json.lock"])
    }

    @Test func readsEveryCallSoARevokeHoldsAtOnce() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .phone, abilities: [.read], key: phone)
        try book.update { $0.append(record) }
        let other = DeviceBook(url: book.url)
        try other.remove(record.id)
        #expect(try book.record(record.id) == nil)
        #expect(try book.read().rev == 2)
    }

    @Test func badChangesLeaveTheFileAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .phone, abilities: [.read], key: phone)
        try book.update { $0.append(record) }
        let before = try Data(contentsOf: book.url)
        #expect(throws: TrustError.invalidRecord("owner")) {
            try book.update { $0[0].owner = true }
        }
        #expect(throws: TrustError.invalidRecord("duplicate id")) { try book.update { $0.append(record) } }
        #expect(throws: TrustError.invalidRecord("nodeKeys")) { try book.update { $0[0].nodeKeys = ["a", "b", "c", "d"] } }
        #expect(throws: TrustError.invalidRecord("tagged abilities")) {
            try book.update { $0[0].userId = nil; $0[0].tags = ["tag:server"]; $0[0].abilities = .run }
        }
        #expect(try Data(contentsOf: book.url) == before)
    }

    @Test func concurrentWritersEachRaiseTheRev() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = book.url
        let key = phone.publicKey
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let r = DeviceRecord(id: UUID(), name: "p\(i)", kind: .phone, abilities: .read, identityKey: key, nodeKeys: [], userId: 1, fqdn: "p", added: Date())
                    _ = try? DeviceBook(url: url).update { $0.append(r) }
                }
            }
        }
        let final = try book.read()
        #expect(final.rev == 16)
        #expect(final.devices.count == 16)
    }

    @Test func devicesSetOnlyFromAnOwnerMacAndOnlyNewer() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let macRecord = TestKit.record(kind: .mac, abilities: .run, key: mac, owner: true)
        let phoneRecord = TestKit.record(kind: .phone, abilities: [.read, .ask], key: phone, issuedBy: macRecord.id)
        try book.update { $0 = [macRecord, phoneRecord] }
        let macProof = try verified(mac, record: macRecord)
        let phoneProof = try verified(phone, record: phoneRecord)
        #expect(throws: TrustError.refused("devices.set from a non-owner")) { try book.apply(rev: 9, devices: [], from: phoneProof) }
        #expect(throws: TrustError.staleRev) { try book.apply(rev: 1, devices: [macRecord], from: macProof) }
        let next = try book.apply(rev: 5, devices: [macRecord], from: macProof)
        #expect(next.rev == 5 && next.devices == [macRecord])
    }

    @Test func revokingAMacDropsWhatItIssued() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let macRecord = TestKit.record(kind: .mac, abilities: .run, key: mac, owner: true)
        let phoneRecord = TestKit.record(kind: .phone, abilities: [.read], key: phone, issuedBy: macRecord.id)
        let box = TestKit.record(kind: .box, abilities: .run, key: SoftwareIdentity())
        try book.update { $0 = [macRecord, phoneRecord, box] }
        try book.remove(macRecord.id)
        #expect(try book.read().devices == [box])
    }

    private func verified(_ key: SoftwareIdentity, record: DeviceRecord, nodeKey: String = "nodekey:new") throws -> VerifiedPeer {
        let b = try Binding(route: "tailnet", nonceS: Data(count: 32), nonceC: Data(count: 32), deviceC: record.id, deviceS: UUID(), nodeKeyC: nodeKey, nodeKeyS: "nodekey:s")
        return try #require(IdentityProof.verify(try IdentityProof.sign(b, with: key), binding: b, side: .client, record: record))
    }

    @Test func nodeKeyAppendsOnlyAfterProofKeepingThree() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .phone, abilities: [.read, .ask], key: phone, nodeKeys: ["nodekey:1", "nodekey:2"], userId: 42)
        try book.update { $0.append(record) }
        #expect(try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:2"), whoisUserId: 42, whoisTags: []) == .known)
        #expect(try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:3"), whoisUserId: 42, whoisTags: []) == .appended(dropped: nil))
        #expect(try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:4"), whoisUserId: 42, whoisTags: []) == .appended(dropped: "nodekey:1"))
        #expect(try book.record(record.id)?.nodeKeys == ["nodekey:2", "nodekey:3", "nodekey:4"])
        // Another user's WhoIs, a failed WhoIs, a tagged answer: refused, nothing kept.
        #expect(throws: TrustError.refused("whois")) { try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:5"), whoisUserId: 43, whoisTags: []) }
        #expect(throws: TrustError.refused("whois")) { try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:5"), whoisUserId: nil, whoisTags: []) }
        #expect(throws: TrustError.refused("whois")) { try book.appendNodeKey(verified(phone, record: record, nodeKey: "nodekey:5"), whoisUserId: 42, whoisTags: ["tag:x"]) }
        #expect(try book.record(record.id)?.nodeKeys == ["nodekey:2", "nodekey:3", "nodekey:4"])
    }

    @Test func nodeKeyAppendRefusesSSHAndAChangedIdentity() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .phone, abilities: [.read], key: phone, userId: 42)
        try book.update { $0.append(record) }
        let b = try Binding(route: "ssh", nonceS: Data(count: 32), nonceC: Data(count: 32), deviceC: record.id, deviceS: UUID(), nodeKeyC: "ssh", nodeKeyS: "ssh")
        let sshPeer = try #require(IdentityProof.verify(try IdentityProof.sign(b, with: phone), binding: b, side: .client, record: record))
        #expect(throws: TrustError.refused("node key off the tailnet")) { try book.appendNodeKey(sshPeer, whoisUserId: 42, whoisTags: []) }
        // The proof was made against an older record whose key has since been replaced.
        let proof = try verified(phone, record: record)
        try book.update { $0[0].identityKey = SoftwareIdentity().publicKey }
        #expect(throws: TrustError.refused("identity key differs")) { try book.appendNodeKey(proof, whoisUserId: 42, whoisTags: []) }
    }

    @Test func taggedRecordsMatchByTags() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .box, abilities: [.read, .ask], key: mac, userId: nil, tags: ["tag:kore", "tag:box"])
        try book.update { $0.append(record) }
        #expect(try book.appendNodeKey(verified(mac, record: record), whoisUserId: nil, whoisTags: ["tag:box", "tag:kore"]) == .appended(dropped: nil))
        #expect(throws: TrustError.refused("whois")) { try book.appendNodeKey(verified(mac, record: record, nodeKey: "nodekey:z"), whoisUserId: nil, whoisTags: ["tag:box"]) }
    }

    @Test func recordJSONIsStrict() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = TestKit.record(kind: .phone, abilities: [.read, .ask], key: phone)
        let json = String(decoding: try TrustJSON.encoder().encode(record), as: UTF8.self)
        #expect(json.contains("\"abilities\" : [\n    \"read\",\n    \"ask\"\n  ]"))
        #expect(try TrustJSON.decoder().decode(DeviceRecord.self, from: Data(json.utf8)) == record)
        for bad in [json.replacingOccurrences(of: "\"ask\"", with: "\"admin\""), json.replacingOccurrences(of: "\"ask\"", with: "\"read\"")] {
            #expect(throws: DecodingError.self) { try TrustJSON.decoder().decode(DeviceRecord.self, from: Data(bad.utf8)) }
        }
        // A book in an unknown version is refused, not guessed at.
        try PrivateFile.write(Data(#"{"v":2,"rev":1,"devices":[]}"#.utf8), to: book.url)
        #expect(throws: TrustError.self) { try book.read() }
    }
}

/// The app capability: strict shape, tagged nodes capped at read+ask.
@Suite("app capability")
struct AppCapTests {
    func cap(_ json: String) throws -> [String: [JSONValue]] {
        try JSONDecoder().decode([String: [JSONValue]].self, from: Data(json.utf8))
    }

    @Test func validGrantsAndTheTaggedCap() throws {
        let one = try cap(#"{"\#(KoreCapDomain)":[{"v":1,"abilities":["read","ask"]}]}"#)
        #expect(AppCap.abilities(capMap: one, tagged: false) == [.read, .ask])
        let run = try cap(#"{"\#(KoreCapDomain)":[{"v":1,"abilities":["run"]}]}"#)
        #expect(AppCap.abilities(capMap: run, tagged: false) == .run)
        #expect(AppCap.abilities(capMap: run, tagged: true) == [.read, .ask])
        let two = try cap(#"{"\#(KoreCapDomain)":[{"v":1,"abilities":["read"]},{"v":1,"abilities":["ask"]}]}"#)
        #expect(AppCap.abilities(capMap: two, tagged: true) == [.read, .ask])
    }

    @Test(arguments: [
        #"{}"#,
        #"{"other.example/cap":[{"v":1,"abilities":["read"]}]}"#,
        #"{"KEY":[]}"#,
        #"{"KEY":[{"v":2,"abilities":["read"]}]}"#,
        #"{"KEY":[{"v":true,"abilities":["read"]}]}"#,
        #"{"KEY":[{"v":"1","abilities":["read"]}]}"#,
        #"{"KEY":[{"v":1.5,"abilities":["read"]}]}"#,
        #"{"KEY":[{"v":1,"abilities":[]}]}"#,
        #"{"KEY":[{"v":1,"abilities":["read","read"]}]}"#,
        #"{"KEY":[{"v":1,"abilities":["admin"]}]}"#,
        #"{"KEY":[{"v":1,"abilities":"read"}]}"#,
        #"{"KEY":[{"v":1,"abilities":[1]}]}"#,
        #"{"KEY":[{"v":1}]}"#,
        #"{"KEY":[{"v":1,"abilities":["read"],"extra":true}]}"#,
        #"{"KEY":[{"v":1,"abilities":["read"]},{"v":1,"abilities":["nope"]}]}"#,
        #"{"KEY":["read"]}"#,
    ])
    func malformedGrantsGiveNothing(_ json: String) throws {
        let map = try cap(json.replacingOccurrences(of: "KEY", with: KoreCapDomain))
        #expect(AppCap.abilities(capMap: map, tagged: false) == nil)
        #expect(AppCap.abilities(capMap: map, tagged: true) == nil)
    }

    @Test func noCapMapIsNoGrant() {
        #expect(AppCap.abilities(capMap: nil, tagged: true) == nil)
        #expect(KoreCapDomain.hasPrefix("kore.invalid/"))
    }
}
