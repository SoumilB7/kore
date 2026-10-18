import Testing

@testable import KoreCore

@Suite("quick open's fuzzy match")
struct FuzzyMatchTests {
    private func match(_ query: String, _ path: String) -> FuzzyMatch.Result? {
        FuzzyMatch.match(Array(query.utf16), in: path)
    }

    @Test func matchesCharactersInOrderIgnoringCase() {
        #expect(match("gsw", "Sources/Greet.swift") != nil)
        #expect(match("GREET", "Sources/Greet.swift") != nil)
        #expect(match("swg", "Sources/Greet.swift") == nil)
    }

    @Test func prefersTheNameOverTheFolder() throws {
        let inName = try #require(match("views", "src/Views.swift"))
        let inFolder = try #require(match("views", "src/views/a.swift"))
        #expect(inName.score > inFolder.score)
    }

    @Test func reportsMatchedPositions() throws {
        let result = try #require(match("gr", "Sources/Greet.swift"))
        #expect(result.positions == [8, 9])
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(match("", "anything")?.score == 0)
    }
}
