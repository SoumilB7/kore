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
