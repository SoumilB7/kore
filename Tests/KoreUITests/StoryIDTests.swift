import Foundation
import Testing

@testable import KoreUI

/// Storyline names (phase 12 plan §3): one grammar, every fixed name unique.
struct StoryIDTests {
    @Test func everyNameFollowsTheGrammar() {
        let grammar = /^[a-z]+(\.[a-z]+)*(\[[^\]]*\])?(\.[a-z]+)*$/
        for name in StoryID.all {
            #expect(name.wholeMatch(of: grammar) != nil, "\(name)")
        }
    }

    @Test func namesAreUnique() {
        #expect(Set(StoryID.all).count == StoryID.all.count)
    }

    @Test func keysAreKoreIdsWithClosingBracketsEscaped() {
        let id = UUID()
        #expect(StoryID.Transcript.answer(id).part(.fork).raw == "transcript.answer[\(id.uuidString)].fork")
        #expect(StoryID.Explorer.row("Sources/a]b.swift").raw == "explorer.row[Sources/a%5Db.swift]")
        #expect(StoryID.Editor.gutterFold(29).raw == "editor.gutter.fold[29]")
        #expect(StoryID.Editor.Find.replaceField.raw == "editor.find.replace.field")
        #expect(StoryID.Approval.card("a1").part(.allow).raw == "approval[a1].allow")
    }
}
