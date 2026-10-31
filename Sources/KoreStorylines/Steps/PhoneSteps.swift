import Foundation
import KorePhone
import KoreRemote
import KoreUI

/// A phone for a storyline: Kore Phone's host with a test client on a loopback link. Finished,
/// it disconnects and the host turns off, so the next storyline starts clean.
@MainActor
final class StoryPhone: StoryFinishing {
    private(set) var client: RemoteTestClient?
    /// The phone's keys, the Mac it paired with, and its encrypted link (the secure path).
    let identity = PhoneIdentity(name: "Story phone")
    var paired: PairedMac?
    var secure: SecureLink?
    var secureFailure: (any Error)?

    func connect(mode: WireMessage.Presence, attnAfter: Int?) {
        let (host, phone) = LoopbackLink.pair()
        RemoteHost.shared.connect(host)
        let client = RemoteTestClient(link: phone)
        client.hello(mode: mode, attnAfter: attnAfter)
        self.client = client
    }

    func disconnect() {
        client?.disconnect()
        client = nil
    }

    private var installedKorePhone = false

    /// Kore Phone's controls for this storyline; taken out again as it finishes.
    func installKorePhone() {
        guard !KorePhone.installed else { return }
        KorePhone.install()
        installedKorePhone = true
    }

    func use(_ link: SecureLink) {
        secure = link
        client = RemoteTestClient(link: link)
    }

    func finish() {
        disconnect()
        secure?.close()
        secure = nil
        RemoteHost.shared.service.disable()
        RemoteHost.shared.turnOff()
        PhoneService.dialer = nil
        if installedKorePhone { KorePhone.uninstall() }
    }
}

extension StoryContext {
    var phone: StoryPhone { stash(StoryPhone.self) { StoryPhone() } }

    func phoneClient() throws -> RemoteTestClient {
        guard let client = phone.client else { throw StoryFailure.modelMissing("a connected phone") }
        return client
    }

    /// The active chat's id on the wire.
    func activeChatID() throws -> String { try activeChat().id.uuidString }
}

/// Connects a phone to the Mac (Kore Phone's host, on a loopback link) and waits for its welcome,
/// and in the foreground for its snapshot.
struct AttachPhone: Step {
    var mode = WireMessage.Presence.foreground
    /// Resume attention from the last id the phone saw before it went away.
    var resumeAttention = false
    var label: String { "Connect a phone (\(mode.rawValue))" + (resumeAttention ? ", resuming its alerts" : "") }

    func run(_ story: StoryContext) async throws {
        let last = story.phone.client?.lastAid ?? StoryPhoneMemory.lastAid
        story.phone.connect(mode: mode, attnAfter: resumeAttention ? last : nil)
        let client = try story.phoneClient()
        try await story.until("the phone's welcome") { client.welcome != nil }
        if mode == .foreground { try await story.until("the phone's snapshot") { client.rev > 0 } }
    }
}

/// What a phone that went away last saw, for its return.
@MainActor
enum StoryPhoneMemory {
    static var lastAid = 0
}

/// The phone goes away (its link closes).
struct DisconnectPhone: Step {
    var label: String { "Disconnect the phone" }

    func run(_ story: StoryContext) async throws {
        StoryPhoneMemory.lastAid = try story.phoneClient().lastAid
        story.phone.disconnect()
        try await story.until("the Mac to see it go") { RemoteHost.shared.phones == 0 }
    }
}

/// The phone opens the active chat's transcript and waits for its first page.
struct PhoneOpensChat: Step {
    var label: String { "The phone opens the chat" }

    func run(_ story: StoryContext) async throws {
        let client = try story.phoneClient()
        let id = try story.activeChatID()
        client.open(id)
        try await story.until("the transcript on the phone") { client.transcripts[id] != nil }
    }
}

/// The phone answers the active chat's card `card` with `action`, signed over the card's
/// digest as the phone was shown it.
struct PhoneAnswer: Step {
    let card: String
    let action: CardAction.ID
    var refused: ResultCode?
    var label: String { "The phone answers “\(card)”: \(action.rawValue)" + (refused.map { " (refused: \($0.rawValue))" } ?? "") }

    func run(_ story: StoryContext) async throws {
        let client = try story.phoneClient()
        let chat = try story.activeChatID()
        let shown = try await story.wait("the card on the phone") { client.chats[chat]?.cards.first { $0.id == card } }
        let digest = shown.digest ?? ""
        let sig = story.phone.secure.map { PhoneSide.approve($0, identity: story.phone.identity, cardId: card, digest: digest, action: action.rawValue) } ?? "loopback"
        let id = client.command(.answer(chatId: chat, cardId: card, action: action, answers: nil, proof: AnswerProof(digest: digest, sig: sig)))
        let result = try await story.wait("the result of answering") { client.results[id] }
        if let refused {
            guard !result.ok, result.code == refused else {
                throw StoryFailure.expectation("answering refused with \(refused.rawValue) (got ok \(result.ok), \(result.code?.rawValue ?? "no code"))")
            }
        } else if !result.ok {
            throw StoryFailure.expectation("answering to go through (refused: \(result.code?.rawValue ?? "?"))")
        }
    }
}

/// The phone sends a command for the active chat and waits for its result.
struct PhoneCommand: Step {
    let what: String
    let command: @MainActor (String) -> RemoteCommand
    /// nil: it must succeed; else the code it must be refused with.
    var refused: ResultCode?
    var label: String { "The phone: \(what)" + (refused.map { " (refused: \($0.rawValue))" } ?? "") }

    func run(_ story: StoryContext) async throws {
        let client = try story.phoneClient()
        let id = client.command(command(try story.activeChatID()))
        let result = try await story.wait("the result of “\(what)”") { client.results[id] }
        if let refused {
            guard !result.ok, result.code == refused else {
                throw StoryFailure.expectation("“\(what)” refused with \(refused.rawValue) (got ok \(result.ok), \(result.code?.rawValue ?? "no code"))")
            }
        } else if !result.ok {
            throw StoryFailure.expectation("“\(what)” to go through (refused: \(result.code?.rawValue ?? "?"))")
        }
    }
}

extension Expect {
    /// Checks what the phone was told about the active chat.
    @MainActor static func phone(
        _ what: String, _ check: @escaping @MainActor (RemoteTestClient, String) throws -> Bool
    ) -> Expect {
        Expect("on the phone: " + what) { story in try check(story.phoneClient(), story.activeChatID()) }
    }
}

extension RemoteTestClient {
    /// The plain text of an entry: its text, or its render tree's words.
    func words(_ entry: WireEntry) -> String {
        if let text = entry.text { return text }
        func spans(_ s: [Span]) -> String { s.map(\.text).joined() }
        func block(_ b: Block) -> String {
            switch b {
            case .heading(_, let s), .paragraph(let s): spans(s)
            case .code(_, let text, _): text
            case .list(_, _, let items): items.flatMap { $0.blocks.map(block) }.joined(separator: "\n")
            case .quote(let blocks): blocks.map(block).joined(separator: "\n")
            case .table(let header, let rows): (header + rows.flatMap { $0 }).map(spans).joined(separator: " ")
            case .rule, .unknown: ""
            }
        }
        return (entry.doc ?? []).map(block).joined(separator: "\n")
    }

    /// A transcript's entries as (kind, words).
    func lines(_ chatId: String) -> [(kind: WireEntry.Kind, text: String)] {
        (transcripts[chatId]?.list ?? []).map { ($0.kind, words($0)) }
    }
}
