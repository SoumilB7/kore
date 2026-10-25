import Foundation
import Testing

@testable import KoreUI

/// A bare URL in a reply's paragraph is a link, as one beside markdown already was.
@Suite("Bare links")
struct BareLinkTests {
    private func links(_ text: String) -> [URL] {
        let blocks = MarkdownParser.parse(text[...], base: 0, zoom: 1)
        guard case .paragraph(let string) = blocks.first?.kind else { return [] }
        return string.runs.compactMap(\.link)
    }

    @Test func bareURLsLink() {
        #expect(links("Standard: https://www.youtube.com/watch?v=dQw4w9WgXcQ").map(\.absoluteString)
            == ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
        #expect(links("Short form: https://youtu.be/dQw4w9WgXcQ").map(\.absoluteString) == ["https://youtu.be/dQw4w9WgXcQ"])
        #expect(links("See www.example.com for more").count == 1)
    }

    @Test func plainTextStaysPlain() {
        #expect(links("Nothing to link here, just words.").isEmpty)
    }
}
