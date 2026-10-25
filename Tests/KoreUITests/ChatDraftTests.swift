import Foundation
import Testing
@testable import KoreUI

@MainActor @Suite("Unsent composer recovery", .serialized)
struct ChatDraftTests {
    private func chat(_ provider: String = "claude", folder: URL = URL(fileURLWithPath: "/tmp/draft-recovery")) throws -> Chat {
        Chat(provider: try #require(Registry.provider(provider)), folder: folder)
    }

    @Test func codableRoundTripKeepsExactWhitespaceCommandAndFilesBeforeControlsLoad() throws {
        let original = try chat()
        defer { original.close() }
        let command = SlashCommand(name: "review", description: "Review changes", hint: "[files]", kind: .command, glyph: "doc")
        original.draft = " \t first line\n\nlast line  \n"
        original.command = command
        let url = URL(fileURLWithPath: "/tmp/draft-recovery/notes with spaces.txt")
        original.attach([url, url])
        let saved = original.composerDraft
        let decoded = try JSONDecoder().decode(ChatDraft.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        let reopened = try chat()
        defer { reopened.close() }
        #expect(reopened.controls.commands.isEmpty)
        #expect(reopened.restoreComposerDraft(decoded))
        #expect(reopened.draft == " \t first line\n\nlast line  \n")
        #expect(Array(reopened.draft.utf8) == Array(original.draft.utf8))
        #expect(reopened.command == command)
        #expect(reopened.attachments.compactMap(\.url) == [url, url])
        #expect(reopened.composerDraft == saved)
        #expect(!reopened.isRunning && reopened.transcript.entries.isEmpty)
    }

    @Test func attachmentReferencesSurviveUndoWithoutRecreatingTheirIDs() throws {
        let original = try chat()
        defer { original.close() }
        original.attach([URL(fileURLWithPath: "/tmp/repeated.txt"), URL(fileURLWithPath: "/tmp/repeated.txt")])
        let retained = original.attachments
        let reopened = try chat()
        defer { reopened.close() }
        #expect(reopened.restoreComposerDraft(original.composerDraft, keeping: retained))
        #expect(reopened.attachments.map(\.id) == retained.map(\.id))
        #expect(reopened.attachments[0].id != reopened.attachments[1].id)
    }

    @Test func draftsCannotMoveAcrossProvidersOrFoldersAndRemoteURLsAreNotAttached() throws {
        let original = try chat(), otherCLI = try chat("codex"), otherFolder = try chat(folder: URL(fileURLWithPath: "/tmp/other-draft-folder"))
        defer { original.close(); otherCLI.close(); otherFolder.close() }
        original.draft = "private draft"
        #expect(!otherCLI.restoreComposerDraft(original.composerDraft))
        #expect(!otherFolder.restoreComposerDraft(original.composerDraft))
        #expect(otherCLI.composerDraft.isEmpty && otherFolder.composerDraft.isEmpty)
        let remote = ChatDraft(provider: "claude", folder: original.folder, text: "only text", attachmentURLs: [try #require(URL(string: "https://example.com/file.png"))])
        #expect(original.restoreComposerDraft(remote))
        #expect(original.draft == "only text" && original.attachments.isEmpty)
    }

    @Test func changesNotifyPersistenceWithoutReadingTheComposerFromASwiftUIBody() throws {
        let chat = try chat()
        defer { chat.onDraftChanged = nil; chat.close() }
        var changes = 0
        chat.onDraftChanged = { changes += 1 }
        chat.draft = " \n"
        chat.draft = " \n"
        #expect(changes == 1 && !chat.composerDraft.isEmpty)
        chat.command = SlashCommand(name: "review", description: "", hint: "", kind: .command)
        #expect(changes == 2)
        chat.attach([URL(fileURLWithPath: "/tmp/draft.txt")])
        #expect(changes == 3)
        let target = ChatDraft(provider: "claude", folder: chat.folder, text: "restored")
        #expect(chat.restoreComposerDraft(target))
        #expect(changes == 4)
        #expect(chat.restoreComposerDraft(target))
        #expect(changes == 4)
        chat.removeAttachment(UUID())
        #expect(changes == 4)
    }
}
