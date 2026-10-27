import Testing

@testable import KoreUI

/// The @ menu's "@word" and its one search over files, folders, models, skills and tabs.
@Suite("@ search in the composer")
struct AtSearchTests {
    static let candidates = AtCandidates(
        files: ["README.md", "Sources/Read/Reader.swift", "docs/readme-old.txt", "Sources/App/Main.swift", "haiku.txt"],
        folders: ["Sources", "Sources/Read", "Sources/App", "docs"],
        recent: ["Sources/App/Main.swift"],
        models: [
            ModelOption(id: "haiku", name: "Haiku", resolved: "haiku", efforts: []),
            ModelOption(id: "opus", name: "Opus", resolved: "opus", efforts: []),
        ],
        currentModel: "opus",
        skills: [SlashCommand(name: "pdf", description: "Read PDFs", hint: "", kind: .skill)],
        tabs: [AtCandidates.Tab(id: "t1", title: "Fix the reader")])

    func token(_ text: String) -> SlashToken? {
        SlashToken(in: text, caret: text.endIndex, skills: false, mentions: true)
    }

    @Test func findsTheMentionWithItsPath() {
        #expect(token("@")?.query == "")
        #expect(token("look at @Sources/Re")?.query == "sources/re")
        #expect(token("mail me@home") == nil)
        #expect(token("@a@b") == nil)
        #expect(SlashToken(in: "@x", caret: "@x".endIndex, skills: false) == nil)
        // The slash menu's word still ends at a path.
        #expect(SlashToken(in: "/a/b", caret: "/a/b".endIndex, skills: false, mentions: true) == nil)
    }

    @Test func bestMatchFirstGroupedByKind() {
        let items = AtRank.rank("read", Self.candidates)
        #expect(items.first?.id == "file:README.md")
        // Each kind together, once.
        var seen: [AtItem.Kind] = []
        for item in items where seen.last != item.kind {
            #expect(!seen.contains(item.kind))
            seen.append(item.kind)
        }
        #expect(seen.first == .file)
        #expect(seen.contains(.folder) && seen.contains(.tab) && !seen.contains(.model))
        // Within a kind, best first: the name match before the path match.
        let files = items.filter { $0.kind == .file }.map(\.key)
        #expect(files.firstIndex(of: "README.md")! < files.firstIndex(of: "Sources/Read/Reader.swift")!)
    }

    @Test func aModelLeadsWhenItMatchesBest() {
        let items = AtRank.rank("hai", Self.candidates)
        #expect(items.first?.id == "model:haiku")
        #expect(items.contains { $0.id == "file:haiku.txt" })
        #expect(!items.contains { $0.id == "model:opus" })
    }

    @Test func aBareAtListsRecentFilesAndEveryKind() {
        let items = AtRank.rank("", Self.candidates)
        #expect(items.map(\.kind) == [.file, .model, .model, .skill, .tab])
        #expect(items[0].key == "Sources/App/Main.swift")
        #expect(items.first { $0.key == "opus" }?.detail == "current")
    }

    @Test func eachKindIsCapped() {
        var many = AtCandidates()
        many.files = (0..<5000).map { "src/file\($0).swift" }
        many.folders = AtRank.folders(of: many.files)
        let items = AtRank.rank("file", many)
        #expect(items.filter { $0.kind == .file }.count == AtItem.Kind.file.cap)
        #expect(items.count <= AtItem.Kind.allCases.map(\.cap).reduce(0, +))
    }

    @Test func foldersOfFilesEachOnce() {
        #expect(AtRank.folders(of: ["a/b/c.txt", "a/b/d.txt", "a/e.txt", "f.txt"]) == ["a/b", "a"])
    }
}
