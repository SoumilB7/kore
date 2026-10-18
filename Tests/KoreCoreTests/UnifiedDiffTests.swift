import Foundation
import Testing

@testable import KoreCore

@Suite("unified diffs, one change per file")
struct UnifiedDiffTests {
    let patch = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1,3 +1,3 @@
         # Demo
         
        -A tiny projcet for trying Kore.
        +A tiny project for trying Kore.
        diff --git a/CHANGELOG.md b/CHANGELOG.md
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/CHANGELOG.md
        @@ -0,0 +1,2 @@
        +# Changelog
        +- First entry
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index 4444444..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """

    @Test func splitsByFileWithCounts() {
        let files = UnifiedDiff.files(patch, root: URL(fileURLWithPath: "/repo"))
        #expect(files.map(\.path) == ["/repo/README.md", "/repo/CHANGELOG.md", "/repo/old.txt"])
        #expect(files.map(\.added) == [1, 2, 0])
        #expect(files.map(\.removed) == [1, 0, 1])
    }

    @Test func knowsNewAndDeletedFiles() {
        let files = UnifiedDiff.files(patch, root: URL(fileURLWithPath: "/repo"))
        #expect(files[0].kind == .update)
        #expect(files[1].kind == .add)
        #expect(files[2].kind == .delete)
    }

    @Test func anEmptyPatchHasNoFiles() {
        #expect(UnifiedDiff.files("").isEmpty)
    }
}

@Suite("unified diffs: renames, binaries, numbering, the budget")
struct UnifiedDiffEdgeTests {
    @Test func aRenameIsAMoveFromTheOldPath() {
        let patch = """
            diff --git a/old name.txt b/new name.txt
            similarity index 90%
            rename from old name.txt
            rename to new name.txt
            index 1111111..2222222 100644
            --- a/old name.txt
            +++ b/new name.txt
            @@ -1 +1 @@
            -a
            +b
            """
        let file = UnifiedDiff.files(patch, root: URL(fileURLWithPath: "/repo")).first
        #expect(file?.path == "/repo/new name.txt")
        #expect(file?.kind == .move(from: "/repo/old name.txt"))
        #expect(file.map { ($0.added, $0.removed) } ?? (0, 0) == (1, 1))
    }

    @Test func aBinaryFileTakesItsPathFromTheHeader() {
        let patch = """
            diff --git a/logo.png b/logo.png
            index 1111111..2222222 100644
            Binary files a/logo.png and b/logo.png differ
            """
        let file = UnifiedDiff.files(patch, root: URL(fileURLWithPath: "/repo")).first
        #expect(file?.path == "/repo/logo.png")
        #expect(file?.isBinary == true)
        #expect(file?.hunks.isEmpty == true)
    }

    @Test func noNewlineMarkersAreNotLines() {
        let parsed = UnifiedDiff.hunks("""
            @@ -1 +1 @@
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """)
        #expect(parsed.hunks.first?.lines.map(\.text) == ["old", "new"])
        #expect((parsed.added, parsed.removed) == (1, 1))
    }

    /// `-U0` hunks: lines numbered from each hunk's own start; a pure deletion's `+n,0`.
    @Test func zeroContextHunksNumberFromTheirStarts() {
        let parsed = UnifiedDiff.hunks("""
            @@ -5 +5 @@
            -five
            +5
            @@ -10,0 +11,2 @@
            +eleven
            +twelve
            @@ -20,2 +20,0 @@
            -twenty
            -twenty-one
            """)
        #expect(parsed.hunks.map(\.newStart) == [5, 11, 20])
        #expect(parsed.hunks[1].lines.map(\.new) == [11, 12])
        #expect(parsed.hunks[2].lines.map(\.old) == [20, 21])
    }

    @Test func theLineBudgetCutsHunksButNotCounts() {
        let lines = (1...(FileChange.lineLimit + 10)).map { "+line \($0)" }
        let parsed = UnifiedDiff.hunks("@@ -0,0 +1,\(lines.count) @@\n" + lines.joined(separator: "\n"))
        #expect(parsed.truncated)
        #expect(parsed.hunks.first?.lines.count == FileChange.lineLimit)
        #expect(parsed.added == lines.count)
    }

    @Test func aTurnsEditsMergePerPath() {
        let hunk = FileChange.Hunk(oldStart: 1, newStart: 1, lines: [.init(kind: .add, text: "x", old: nil, new: 1)])
        let merged = FileChange.mergedByPath([
            FileChange(path: "/a", kind: .add, hunks: [hunk]),
            FileChange(path: "/b", kind: .update, hunks: [hunk]),
            FileChange(path: "/a", kind: .update, hunks: [hunk]),
        ])
        #expect(merged.map(\.path) == ["/a", "/b"])
        #expect(merged[0].kind == .add)
        #expect(merged[0].added == 2)
        let gone = FileChange.mergedByPath([FileChange(path: "/c", kind: .add, hunks: [hunk]), FileChange(path: "/c", kind: .delete, hunks: [])])
        #expect(gone.first?.kind == .delete)
    }
}
