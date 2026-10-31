import Foundation
import KorePhone
import KoreRemote
import KoreUI

extension StoryContext {
    /// The storyline's relay: in-process, the same rules as the real one.
    var storyRelay: LoopbackRelay { stash(LoopbackRelay.self) { LoopbackRelay() } }
}

/// Kore Phone's own controls ("/" → Phone, the title-row button), as `kore-phone` installs them.
struct InstallKorePhone: Step {
    var label: String { "Kore Phone's controls installed" }
    func run(_ story: StoryContext) async throws { story.phone.installKorePhone() }
}

/// Phone on, as "/" → Phone's switch does it: the Mac's mailbox opened on the storyline's relay.
struct PhoneOn: Step {
    var label: String { "Turn Phone on" }

    func run(_ story: StoryContext) async throws {
        story.phone.installKorePhone()
        PhoneService.dialer = story.storyRelay.dialer
        RemoteHost.shared.service.enable()
        try await story.until("the mailbox open on the relay") { RemoteHost.shared.phone.relay == .connected }
    }
}

/// Phone off: every phone told, every pairing forgotten, the mailbox closed.
struct PhoneOff: Step {
    var label: String { "Turn Phone off" }

    func run(_ story: StoryContext) async throws {
        RemoteHost.shared.service.disable()
        try await story.until("Phone off") { !RemoteHost.shared.phone.isOn }
    }
}

/// The phone scans the QR, shows its code, and the owner types it on the Mac.
struct SecurePhonePairs: Step {
    /// Types other codes three times instead of the phone's.
    var wrongCode = false
    var label: String { wrongCode ? "A phone pairs; the owner types the wrong code three times" : "A phone pairs; the owner types its code on the Mac" }

    func run(_ story: StoryContext) async throws {
        let service = RemoteHost.shared.service
        let model = RemoteHost.shared.phone
        service.startPairing()
        let offer = try await story.wait("the QR") { service.lastOffer }
        let shown = Locked<String?>(nil)
        let identity = story.phone.identity
        let dial = story.storyRelay.dialer
        let pairing = Task { try await PhoneSide.pair(via: dial, code: offer, identity: identity) { code in shown.withLock { $0 = code } } }
        try await story.until("the Mac asking for the code") { if case .typing = model.pairing { true } else { false } }
        let code = try await story.wait("the code on the phone") { shown.withLock { $0 } }
        if wrongCode {
            for typed in ["000000", "111111", "222222"] where typed != code {
                service.submitCode(typed)
                try await Task.sleep(for: .milliseconds(50))
            }
            guard case .failure = await pairing.result else { throw StoryFailure.expectation("the pairing refused after three wrong codes") }
            return
        }
        service.submitCode(code)
        story.phone.paired = try await pairing.value
    }
}

/// The paired phone links (alerts only): its sync hello is the first record.
struct SecurePhoneLinks: Step {
    /// Expect the Mac (or the relay) to refuse it.
    var refused = false
    var label: String { refused ? "The phone's link is refused" : "The phone links (alerts only)" }

    func run(_ story: StoryContext) async throws {
        guard let paired = story.phone.paired else { throw StoryFailure.modelMissing("a paired phone") }
        let hello = try Envelope(.hello(proto: Proto.version, device: .init(name: "Story phone", build: "1"), mode: .foreground, attnAfter: nil, resume: nil))
            .encoded()
        do {
            let link = try await PhoneSide.link(via: story.storyRelay.dialer, mac: paired, identity: story.phone.identity, first: hello)
            if refused {
                try await story.until("the link closed") { link.isClosed }
                return
            }
            story.phone.use(link)
            let client = try story.phoneClient()
            try await story.until("the welcome") { client.welcome != nil }
        } catch {
            guard refused else { throw error }
        }
    }
}

/// The phone steps up to full access (the fingerprint, on a real phone).
struct SecurePhoneUnlocks: Step {
    var label: String { "The phone unlocks (full access)" }

    func run(_ story: StoryContext) async throws {
        guard let link = story.phone.secure else { throw StoryFailure.modelMissing("a linked phone") }
        guard try await PhoneSide.stepUp(link, identity: story.phone.identity) == .full else { throw StoryFailure.expectation("full access") }
        let client = try story.phoneClient()
        try await story.until("Kore's state on the phone") { client.rev > 0 }
    }
}

/// The phone locks: back to alerts only.
struct SecurePhoneLocks: Step {
    var label: String { "The phone locks" }

    func run(_ story: StoryContext) async throws {
        guard let link = story.phone.secure else { throw StoryFailure.modelMissing("a linked phone") }
        link.sendControl(LinkControl("link.lock"))
        try await story.until("alerts only") { link.access == .watch && RemoteHost.shared.phone.anyFull == false }
    }
}

/// The ports this process listens on, as `lsof` sees them.
@MainActor
enum Listening {
    static func ports() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", "\(ProcessInfo.processInfo.processIdentifier)", "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
