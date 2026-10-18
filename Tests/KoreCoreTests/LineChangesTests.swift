import Testing

@testable import KoreCore

@Suite("gutter marks against git HEAD")
struct LineChangesTests {
    @Test func marksAddedAndModifiedLines() async {
        let changes = await GitBaseline.changes(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        #expect(changes.marks[1] == .modified)
        #expect(changes.marks[3] == .added)
        #expect(changes.marks[0] == nil)
    }

    @Test func marksDeletionsAboveTheLineAfter() async {
        let changes = await GitBaseline.changes(from: "a\nb\nc\n", to: "a\nc\n")
        #expect(changes.marks.isEmpty)
        #expect(changes.deletions == [1])
    }

    @Test func identicalTextHasNoMarks() async {
        let changes = await GitBaseline.changes(from: "same\n", to: "same\n")
        #expect(changes == LineChanges())
    }
}
