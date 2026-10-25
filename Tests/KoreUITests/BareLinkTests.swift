import Foundation
import Testing

@testable import KoreUI

/// Only markdown links link: a bare URL stays text, with or without other markup on its line.
@Suite("Bare links")
struct BareLinkTests {
    private func links(_ text: String) -> [URL] {
        let blocks = MarkdownParser.parse(text[...], base: 0, zoom: 1)
        guard case .paragraph(let string) = blocks.first?.kind else { return [] }
        return string.runs.compactMap(\.link)
    }

    @Test func bareURLsStayText() {
        #expect(links("Standard: https://www.youtube.com/watch?v=dQw4w9WgXcQ").isEmpty)
        #expect(links("With a start time: https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s").isEmpty)
        #expect(links("**Bold** then www.example.com").isEmpty)
    }

    @Test func markdownLinksLink() {
        #expect(links("See [the video](https://youtu.be/dQw4w9WgXcQ)").map(\.absoluteString) == ["https://youtu.be/dQw4w9WgXcQ"])
        #expect(links("Or [https://youtu.be/x](https://youtu.be/x)").count == 1)
        #expect(links("Or <https://example.com>").count == 1)
    }
}
