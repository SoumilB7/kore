import Testing

@testable import KoreCore

@Suite("git status, as the explorer colours it")
struct GitStatusTests {
    let status = GitStatus.parse(
        [
            " M Sources/a.swift", "?? notes.txt", "A  added.swift", "R  renamed.swift", "old.swift",
            "!! build/", "UU conflict.swift", "?? scratch/",
        ].joined(separator: "\0") + "\0", root: "/repo")

    @Test func readsEachFilesState() {
        #expect(status.state(of: "/repo/Sources/a.swift") == .modified)
        #expect(status.state(of: "/repo/notes.txt") == .untracked)
        #expect(status.state(of: "/repo/added.swift") == .added)
        #expect(status.state(of: "/repo/renamed.swift") == .renamed)
        #expect(status.state(of: "/repo/conflict.swift") == .conflicted)
    }

    @Test func skipsARenamesOldPath() {
        #expect(status.state(of: "/repo/old.swift") == nil)
    }

    @Test func wholeFoldersCoverWhatsUnderThem() {
        #expect(status.state(of: "/repo/build/out/x.o") == .ignored)
        #expect(status.state(of: "/repo/scratch/a/b.txt") == .untracked)
        #expect(status.state(of: "/repo/scratch") == .untracked)
    }

    @Test func foldersTakeTheirStrongestFile() {
        let mixed = GitStatus.parse("?? Sources/new.swift\0 M Sources/a.swift\0", root: "/repo")
        #expect(mixed.state(of: "/repo/Sources") == .modified)
    }

    @Test func ignoredFilesDontColourTheirFolder() {
        let ignored = GitStatus.parse("!! Sources/cache.bin\0", root: "/repo")
        #expect(ignored.state(of: "/repo/Sources") == nil)
    }

    @Test func cleanPathsHaveNoState() {
        #expect(status.state(of: "/repo/README.md") == nil)
    }
}
