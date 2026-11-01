import Foundation
import Testing

@testable import KoreUI

/// Bare http(s) URLs link like markdown links (GitHub's autolink rules); code stays code.
@Suite("Bare links")
struct BareLinkTests {
    private func links(_ text: String) -> [String] {
        let blocks = MarkdownParser.parse(text[...], base: 0, zoom: 1)
        guard case .paragraph(let string) = blocks.first?.kind else { return [] }
        return string.runs.compactMap(\.link).map(\.absoluteString)
    }

    @Test func bareURLsLink() {
        #expect(links("Fix PR: https://github.com/o/r/pull/5768") == ["https://github.com/o/r/pull/5768"])
        #expect(links("**Bold** then https://example.com/a") == ["https://example.com/a"])
        #expect(links("Watch https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s now") == ["https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s"])
    }

    @Test func trailingPunctuationIsLeftOut() {
        #expect(links("See https://example.com/x.") == ["https://example.com/x"])
        #expect(links("Is it https://example.com/x?") == ["https://example.com/x"])
        #expect(links("(see https://example.com/x)") == ["https://example.com/x"])
        #expect(links("https://en.wikipedia.org/wiki/Swift_(language) ok") == ["https://en.wikipedia.org/wiki/Swift_(language)"])
        #expect(links("a https://example.com/x, b https://example.com/y;") == ["https://example.com/x", "https://example.com/y"])
    }

    @Test func codeStaysCode() {
        #expect(links("Run `curl https://example.com/x` first").isEmpty)
        let blocks = MarkdownParser.parse("```\nhttps://example.com\n```"[...], base: 0, zoom: 1)
        if case .paragraph = blocks.first?.kind { Issue.record("a code block became a paragraph") }
    }

    @Test func markdownLinksLink() {
        #expect(links("See [the video](https://youtu.be/dQw4w9WgXcQ)") == ["https://youtu.be/dQw4w9WgXcQ"])
        #expect(links("Or [https://youtu.be/x](https://youtu.be/x)").count == 1)
        #expect(links("Or <https://example.com>").count == 1)
    }

    @Test func tableCellsLink() {
        let blocks = MarkdownParser.parse("| PR | Link |\n|---|---|\n| fix | https://example.com/pr/1 |"[...], base: 0, zoom: 1)
        guard case .table(let table) = blocks.first?.kind else { Issue.record("no table"); return }
        #expect(table.rows.first?.last?.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com/pr/1"])
    }
}
