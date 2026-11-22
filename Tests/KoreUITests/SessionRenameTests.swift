import Foundation
import KoreCore
import Testing

@testable import KoreUI
@testable import src

/// A rename the CLI made (`/rename` typed in the chat) is the chat's title, and a chat never
/// goes by an empty one.
@MainActor
@Suite("session rename from the CLI")
struct SessionRenameTests {
    static let folder = URL(fileURLWithPath: "/tmp")

    /// Claude 2.1.318's frame after `/rename Device` (its SDK schema `system/session_title_changed`,
    /// sent in print mode at start when named and after each rename).
    static let renamed =
        #"{"type":"system","subtype":"session_title_changed","title":"Device","uuid":"7b6f0d0e-3c1a-4f7e-9a51-2d8c0c2b9e11","session_id":"s1"}"#

    @Test func claudesRenameFrameRenamesTheChat() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        // After a turn: before one, it's only the name said at start (`ForkTitleTests`).
        let events = try ActiveCommandsTests.claude(t, [ForkTitleTests.result, Self.renamed])
        #expect(events.contains { if case .titleChanged("Device", true) = $0 { true } else { false } })
        let status = ChatStatus(resume: nil)
        status.apply(.titleChanged("Claude"))
        events.forEach(status.apply)
        #expect(status.title(fallback: "Claude") == "Device")
        // A blank one is no rename.
        let blank = try ActiveCommandsTests.claude(t, [#"{"type":"system","subtype":"session_title_changed","title":"  ","session_id":"s1"}"#])
        #expect(!blank.contains { if case .titleChanged = $0 { true } else { false } })
    }

    @Test func codexsThreadNameIsTheChatsName() {
        let t = CodexTranslator(folder: Self.folder)
        t.translate(CodexEvent(notification: "thread/name/updated", params: .object(["threadId": "th1", "threadName": "Device"])))
        let events = t.take().events
        #expect(events.contains { if case .titleChanged("Device", true) = $0 { true } else { false } })
        let status = ChatStatus(resume: nil)
        status.apply(.titleChanged("A generated one"))
        events.forEach(status.apply)
        #expect(status.name == "Device")
    }

    /// A generated title goes only where there's no name; a rename always does.
    @Test func aGeneratedTitleNeverReplacesAName() {
        let status = ChatStatus(resume: nil)
        status.apply(.titleChanged("Device", rename: true))
        status.apply(.titleChanged("Summary of the chat"))
        #expect(status.name == "Device")
        status.apply(.titleChanged("Later", rename: true))
        #expect(status.name == "Later")
    }

    @Test func aChatNeverShowsAnEmptyTitle() {
        let past = ChatStatus(resume: SessionSummary(id: "s1", agent: .claude, title: "", updated: .now))
        #expect(past.name == nil && past.title(fallback: "Claude") == "Claude")
        past.name = "   "
        #expect(past.name == nil)
        past.apply(.userMessage(text: "  look at the logs ", attachments: []))
        #expect(past.title(fallback: "Claude") == "look at the logs")
        past.apply(.titleChanged("", rename: true))
        #expect(past.title(fallback: "Claude") == "look at the logs")
    }

    /// The rename flag crosses the link; one without it (an older box's) is a generated title.
    @Test func theRenameFlagIsCoded() throws {
        let data = try JSONEncoder().encode(ChatEvent.titleChanged("Device", rename: true))
        let back = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect({ if case .titleChanged("Device", true) = back { true } else { false } }())
        let old = try JSONDecoder().decode(ChatEvent.self, from: Data(#"{"type":"titleChanged","title":"T"}"#.utf8))
        #expect({ if case .titleChanged("T", false) = old { true } else { false } }())
    }

    @Test func codexOffersRename() {
        #expect(CodexBackend.builtinCommands.contains { $0.name == "rename" })
    }
}
