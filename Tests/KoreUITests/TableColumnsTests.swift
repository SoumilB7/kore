import Testing

@testable import KoreUI

struct TableColumnsTests {
    @Test func fitsAsTheyAreWhenThereIsRoom() {
        #expect(TableColumns.widths([30, 100, 200], within: 400) == [30, 100, 200])
        #expect(TableColumns.widths([30, 100, 200], within: nil) == [30, 100, 200])
    }

    @Test func narrowColumnsKeepTheirWidthAndWideOnesShareTheRest() {
        // 600 into 400: "#" and "Severity" keep theirs; the two long ones split 400 - 30 - 80.
        let widths = TableColumns.widths([30, 80, 900, 700], within: 400)
        #expect(widths[0] == 30 && widths[1] == 80)
        #expect(widths[2] == 145 && widths[3] == 145)
        #expect(widths.reduce(0, +) == 400)
    }

    @Test func neverNarrowerThanTheMinimum() {
        let widths = TableColumns.widths([500, 500, 500, 500], within: 100)
        #expect(widths.allSatisfy { $0 >= Markdown.Document.cellMin })
    }
}
