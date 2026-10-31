import Foundation
import KoreRemote
import Testing

@testable import KorePhone

/// What the phone is sent of Kore's text: markdown as the render tree, parsed by Kore's own
/// parser, and long text cut with its full length kept.
@MainActor
@Suite("remote snapshot")
struct RemoteSnapshotTests {
    @Test func markdownBecomesTheRenderTree() {
        let doc = RemoteSnapshot.doc(
            """
            ## Fixed
            Tax now applies in `total.ts`, **all 42 pass**, see [the PR](https://example.com/pr/1).

            - rounding moved
            - [x] tests

            ```ts
            return round(x)
            ```
            """)
        #expect(doc.first == .heading(level: 2, spans: [Span("Fixed")]))
        guard doc.count > 1, case .paragraph(let spans) = doc[1] else {
            Issue.record("no paragraph: \(doc)")
            return
        }
        #expect(spans.contains(Span("total.ts", code: true)))
        #expect(spans.contains(Span("all 42 pass", strong: true)))
        #expect(spans.contains { $0.text == "the PR" && $0.link == "https://example.com/pr/1" })
        #expect(doc.contains { if case .list(false, _, let items) = $0 { items.count == 2 && items[1].task == true } else { false } })
        #expect(doc.contains(.code(lang: "ts", text: "return round(x)", open: false)))
    }

    @Test func longTextIsCutWithItsLength() {
        let text = String(repeating: "é", count: RemoteSnapshot.textCap + 10)
        let cut = RemoteSnapshot.capped(text, RemoteSnapshot.textCap)
        #expect(cut.cut)
        #expect(cut.length == RemoteSnapshot.textCap + 10)
        #expect(cut.text.unicodeScalars.count == RemoteSnapshot.textCap)
        let output = String(repeating: "a", count: 10_000)
        let shown = RemoteSnapshot.headAndTail(output)
        #expect(shown.count == RemoteSnapshot.resultHead + RemoteSnapshot.resultTail + 3)
    }

    @Test func pathsAreRelative() {
        let folder = URL(fileURLWithPath: "/Users/me/acme")
        #expect(RemoteSnapshot.relative("/Users/me/acme/src/total.ts", to: folder) == "src/total.ts")
        #expect(RemoteSnapshot.relative("/etc/hosts", to: folder) == "/etc/hosts")
    }
}
