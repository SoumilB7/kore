import Foundation
import KoreCore
import SwiftUI
import Testing

@testable import KoreUI

/// Chat code blocks and notebook cells in the editor's colours (`SyntaxText`).
@MainActor
@Suite("Syntax text: coloured blocks")
struct SyntaxTextTests {
    private func colors(_ text: AttributedString) -> Set<String> {
        Set(text.runs.compactMap { $0.foregroundColor.map { "\($0)" } })
    }

    @Test func aBlockIsColouredAndKeptForTheNextAsk() {
        let code = "let name = \"Ada\" // \(UUID().uuidString)"
        #expect(!SyntaxText.isCached(code, .named("swift")))
        let first = SyntaxText.attributed(code, .named("swift"))
        #expect(String(first.characters) == code)
        #expect(colors(first).count >= 3)
        #expect(SyntaxText.isCached(code, .named("swift")))
        #expect(SyntaxText.attributed(code, .named("swift")) == first)
        // The same text in another language is its own entry.
        #expect(!SyntaxText.isCached(code, .named("ts")))
    }

    @Test func jsonKeysTakeTheKeyColour() {
        let text = SyntaxText.attributed(#"{"a": 1}"#, .named("json"))
        let key = text.runs.first { String(text[$0.range].characters) == #""a""# }
        #expect(key?.foregroundColor == Color(nsColor: Theme.Syntax.color(.key)!))
    }

    @Test func punctuationStaysPlainSoABlockIsFewRuns() {
        // `f(a, b)`: a call, its brackets and commas all plain, one run.
        let call = SyntaxText.attributed("f(a, b)", .named("swift"))
        #expect(call.runs.count == 1)
        // `let x = (1)`: the keyword, a plain stretch, the number, a plain bracket.
        let line = SyntaxText.attributed("let x = (1)", .named("swift"))
        #expect(line.runs.count == 4)
    }

    @Test func bigBlocksStayPlain() {
        let lines = String(repeating: "let x = 1\n", count: SyntaxText.maxLines + 1)
        #expect(!SyntaxText.fits(lines))
        #expect(colors(SyntaxText.attributed(lines, .named("swift"))).count == 1)
        #expect(!SyntaxText.isCached(lines, .named("swift")))
        let wide = String(repeating: "x", count: SyntaxText.maxLength + 1)
        #expect(!SyntaxText.fits(wide))
        #expect(SyntaxText.fits(String(repeating: "let x = 1\n", count: 100)))
    }

    @Test func plainLanguagesAreNotScanned() {
        let text = SyntaxText.attributed("just words", .plain)
        #expect(colors(text).count == 1)
        #expect(!SyntaxText.isCached("just words", .plain))
    }
}
