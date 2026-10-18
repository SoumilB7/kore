import Foundation
import Testing

@testable import KoreUI

/// The editor's line starts, updated per edit, must equal a full scan after any edit:
/// `\r\n` joined or split at an edit's edges, U+2028 / U+2029 breaks.
@Suite("Line index")
struct LineIndexTests {
    private static let pieces = ["a", "bc", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "xyz", "é", "🙂"]

    private func text(_ count: Int, _ random: inout Seeded) -> String {
        (0..<count).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
    }

    @Test(arguments: [1, 2, 3, 5, 8, 13, 21, 34] as [UInt64])
    func updateEqualsRebuild(seed: UInt64) {
        var random = Seeded(seed)
        let string = NSMutableString(string: text(40, &random))
        let lines = LineIndex()
        lines.rebuild(string)
        for step in 0..<300 {
            let location = Int.random(in: 0...string.length, using: &random)
            let length = Int.random(in: 0...min(6, string.length - location), using: &random)
            let insert = text(Int.random(in: 0...3, using: &random), &random) as NSString
            string.replaceCharacters(in: NSRange(location: location, length: length), with: insert as String)
            lines.update(string, edited: NSRange(location: location, length: insert.length), delta: insert.length - length)
            let fresh = LineIndex()
            fresh.rebuild(string)
            #expect(lines.starts == fresh.starts, "seed \(seed), step \(step)")
            if lines.starts != fresh.starts { return }
        }
    }

    @Test func aLineRangeLeavesOutItsBreak() {
        let string = "one\r\ntwo\nthree" as NSString
        let lines = LineIndex()
        lines.rebuild(string)
        #expect(lines.count == 3)
        #expect((0..<3).map { string.substring(with: lines.range(of: $0, in: string)) } == ["one", "two", "three"])
        #expect(lines.line(at: 4) == 0)
        #expect(lines.line(at: 5) == 1)
    }

    /// Typing `\n` after a `\r` joins them into one break; deleting the `\n` splits them again.
    @Test func crlfJoinsAndSplitsAtTheEdge() {
        let string = NSMutableString(string: "a\rb")
        let lines = LineIndex()
        lines.rebuild(string)
        #expect(lines.starts == [0, 2])
        string.insert("\n", at: 2)
        lines.update(string, edited: NSRange(location: 2, length: 1), delta: 1)
        #expect(lines.starts == [0, 3])
        string.deleteCharacters(in: NSRange(location: 2, length: 1))
        lines.update(string, edited: NSRange(location: 2, length: 0), delta: -1)
        #expect(lines.starts == [0, 2])
    }
}
