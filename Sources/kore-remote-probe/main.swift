import CryptoKit
import Foundation
import KoreRemote

// A phone without a phone, for checking a Kore Phone through the relay by hand:
//
//   kore-remote-probe pair KORE1.… [--save <file>]       pairs; prints the code to type on the Mac
//   kore-remote-probe link --paired <file> [--stepup]    links, prints what the Mac sends
//   kore-remote-probe attack <case> KORE1.…|--paired <file>
//
// Attack cases: unsupported-version, garbage-preface, wrong-psk, replay-pair, unknown-key,
// stolen-token, guess-mailbox. Each prints "refused" when the Mac (or the relay) turned it away,
// as it must. The saved file holds this run's link keys: a test artefact that dies with the
// pairing. It reuses KoreRemote's phone side as the tests do: nothing here is its own protocol.

struct Saved: Codable {
    var macKey: String
    var pskLink: String
    var relay: String
    var mailbox: String
    var relayToken: String
    var watch: String
    var act: String
}

func arg(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func code() -> PairingCode {
    guard let text = CommandLine.arguments.first(where: { $0.hasPrefix(PairingCode.prefix) }), let code = PairingCode(text: text) else {
        fail("no KORE1. code")
    }
    return code
}

func load() -> (PairedMac, PhoneIdentity) {
    guard let path = arg("--paired"), let data = FileManager.default.contents(atPath: path),
        let saved = try? JSONDecoder().decode(Saved.self, from: data), let mac = Data(base64Encoded: saved.macKey),
        let psk = Data(base64Encoded: saved.pskLink), let mailbox = Data(hexString: saved.mailbox),
        let token = Data(base64Encoded: saved.relayToken), let w = Data(base64Encoded: saved.watch), let a = Data(base64Encoded: saved.act),
        let watch = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: w), let act = try? P256.Signing.PrivateKey(rawRepresentation: a)
    else { fail("no --paired file") }
    let paired = PairedMac(macKey: mac, pskLink: psk, relay: saved.relay, mailbox: mailbox, relayToken: token, name: nil)
    return (paired, PhoneIdentity(name: "Probe", watch: watch, act: act))
}

let hello = Data(#"{"device":{"build":"1","name":"Probe"},"mode":"foreground","proto":{"major":1,"minor":0},"t":"hello"}"#.utf8)

switch CommandLine.arguments.dropFirst().first {
case "pair":
    let c = code()
    let identity = PhoneIdentity(name: "Probe")
    let paired = try await PhoneSide.pair(via: WebSocketRelay.dialer(host: c.relay), code: c, identity: identity) {
        print("Type this code on the Mac: \($0)")
    }
    print("paired")
    if let path = arg("--save") {
        let saved = Saved(
            macKey: paired.macKey.base64EncodedString(), pskLink: paired.pskLink.base64EncodedString(), relay: paired.relay,
            mailbox: paired.mailbox.hexString, relayToken: paired.relayToken.base64EncodedString(),
            watch: identity.watch.rawRepresentation.base64EncodedString(), act: identity.act.rawRepresentation.base64EncodedString())
        try JSONEncoder().encode(saved).write(to: URL(fileURLWithPath: path))
    }
case "link":
    let (mac, identity) = load()
    let link = try await PhoneSide.link(via: WebSocketRelay.dialer(host: mac.relay), mac: mac, identity: identity, first: hello)
    print("linked")
    if CommandLine.arguments.contains("--stepup") { print("access:", try await PhoneSide.stepUp(link, identity: identity).rawValue) }
    for await message in link.incoming { print(messageType(message) ?? "?") }
    print("closed")
case "attack":
    let name = CommandLine.arguments.dropFirst(2).first ?? ""
    let refused = await Attack.run(name)
    print(refused ? "refused" : "ACCEPTED")
    exit(refused ? 0 : 2)
default:
    fail("kore-remote-probe pair|link|attack …")
}

enum Attack {
    static func run(_ name: String) async -> Bool {
        do {
            switch name {
            case "unsupported-version", "garbage-preface":
                let c = code()
                let channel = try await RelayPhoneChannel.join(WebSocketRelay.dialer(host: c.relay), mailbox: c.mailbox, token: KoreKeys.relayPairToken(c.secret))
                try await channel.send(name == "garbage-preface" ? Data("GET / HTTP/1.1\r\n".utf8) : Data([0x4B, 0x52, 9, 1]))
                if name == "unsupported-version" { return try await ChannelReader(channel).exactly(5, within: 5) == Preface.unsupportedHint }
                return await closed(channel)
            case "wrong-psk":
                let c = code()
                let channel = try await RelayPhoneChannel.join(WebSocketRelay.dialer(host: c.relay), mailbox: c.mailbox, token: KoreKeys.relayPairToken(c.secret))
                _ = try await PhoneSide.pair(channel, code: c, identity: PhoneIdentity(), psk: Data(count: 32))
                return false
            case "replay-pair":
                let c = code()
                let dial = WebSocketRelay.dialer(host: c.relay)
                let first = Task { try? await PhoneSide.pair(via: dial, code: c, identity: PhoneIdentity()) }
                try await Task.sleep(for: .milliseconds(500))
                let second = try? await PhoneSide.pair(via: dial, code: c, identity: PhoneIdentity())
                first.cancel()
                return second == nil
            case "unknown-key":
                let (mac, _) = load()
                _ = try await PhoneSide.link(via: WebSocketRelay.dialer(host: mac.relay), mac: mac, identity: PhoneIdentity(), first: hello)
                return false
            case "stolen-token":
                // The relay token alone: it joins the mailbox, but without the phone's keys gets nowhere.
                let (mac, _) = load()
                var stolen = mac
                stolen.pskLink = Data(count: 32)
                _ = try await PhoneSide.link(via: WebSocketRelay.dialer(host: mac.relay), mac: stolen, identity: PhoneIdentity(), first: hello)
                return false
            case "guess-mailbox":
                let (mac, _) = load()
                _ = try await RelayPhoneChannel.join(WebSocketRelay.dialer(host: mac.relay), mailbox: KoreKeys.random(16), token: KoreKeys.random(32))
                return false
            default:
                fail("unknown attack \(name)")
            }
        } catch {
            return true
        }
    }

    /// Whether the Mac closed the session (within `seconds`).
    static func closed(_ channel: any ByteChannel, within seconds: Double = 12) async -> Bool {
        do {
            _ = try await withDeadline(seconds) {
                while true { _ = try await channel.receive() }
            }
            return false
        } catch ChannelError.timedOut {
            return false
        } catch {
            return true
        }
    }
}
