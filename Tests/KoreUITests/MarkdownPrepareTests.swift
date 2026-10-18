import Foundation
import Testing

@testable import KoreUI

/// Replies parsed off the main thread ahead of their rows (`MarkdownCache.prepare`) must be the
/// blocks a row would parse for itself on the main thread: same blocks, same styled text.
@MainActor
@Suite("Markdown: replies prepared off the main thread")
struct MarkdownPrepareTests {
    /// Every block type (the gallery's reply) and the recorded runs' answers.
    private func replies() throws -> [String] {
        var answers = [DevMarkdownGallery.reply]
        for event in try Recorded.all() {
            if case .text(_, .answer, let text, _) = event, !text.isEmpty { answers.append(text) }
        }
        return answers
    }

    @Test func sameBlocksAsParsedOnMain() async throws {
        let texts = try replies()
        let run = UUID().uuidString
        let keys = texts.indices.map { "prepare-\(run)-\($0)" }
        MarkdownCache.shared.prepare(Array(zip(keys, texts)))
        for _ in 0..<500 where keys.contains(where: MarkdownCache.shared.isPreparing) {
            try await Task.sleep(for: .milliseconds(10))
        }
        for (key, text) in zip(keys, texts) {
            let prepared = MarkdownCache.shared.document(key)
            let direct = MarkdownDocument()
            direct.update(text[...])
            #expect(!prepared.blocks.isEmpty || direct.blocks.isEmpty, "\(key) was not prepared")
            #expect(prepared.blocks == direct.blocks, "\(key)")
            // Shown, it keeps the prepared blocks (the same text at the same zoom).
            prepared.update(text[...])
            #expect(prepared.blocks == direct.blocks, "\(key) after update")
        }
    }

    /// A reply that grew after it was prepared parses again from where it grew.
    @Test func preparedThenGrown() async throws {
        let key = "prepare-grown-\(UUID().uuidString)"
        let first = "One paragraph.\n\n- an item\n- another"
        let grown = first + "\n\n```swift\nlet x = 1\n```\n\nAnd **more**."
        MarkdownCache.shared.prepare([(key, first)])
        for _ in 0..<500 where MarkdownCache.shared.isPreparing(key) { try await Task.sleep(for: .milliseconds(10)) }
        let document = MarkdownCache.shared.document(key)
        document.update(grown[...])
        let direct = MarkdownDocument()
        direct.update(grown[...])
        #expect(document.blocks == direct.blocks)
    }
}
