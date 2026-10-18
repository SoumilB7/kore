import Foundation
import Testing

@testable import KoreUI

@Suite("fold regions by indentation")
struct FoldRegionsTests {
    private func regions(_ text: String) -> FoldRegions {
        let string = text as NSString
        let lines = LineIndex()
        lines.rebuild(string)
        return FoldRegions.compute(string, lines: lines, tabWidth: 4)
    }

    @Test func aBodyFoldsUpToItsLastLine() {
        let r = regions("func a() {\n    x\n    y\n}\n")
        #expect(r.end(of: 0) == 2)
        #expect(r.end(of: 3) == nil)
    }

    @Test func nestedRegionsAreInnermostFirst() {
        let r = regions("struct S {\n    func f() {\n        x\n    }\n}\n")
        #expect(r.containing(2).map(\.start) == [1, 0])
    }

    @Test func blankLinesStayInsideButNotAtTheEnd() {
        let r = regions("a\n    b\n\n    c\n\nd\n")
        #expect(r.end(of: 0) == 3)
    }

    @Test func lineIndexFollowsEdits() {
        let lines = LineIndex()
        let before = "one\ntwo\nthree\n" as NSString
        lines.rebuild(before)
        let after = "one\nnew\ntwo\nthree\n" as NSString
        lines.update(after, edited: NSRange(location: 4, length: 4), delta: 4)
        let fresh = LineIndex()
        fresh.rebuild(after)
        #expect(lines.starts == fresh.starts)
    }
}
