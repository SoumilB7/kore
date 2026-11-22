import Foundation
@testable import src
import SwiftUI
import Testing

@testable import KoreUI

/// A numbered list that goes on from an earlier one ("**B. …**" then "5.") is a list, not the end
/// of a paragraph, where it plainly is one: under a lead line (all bold, or ending in a colon), or
/// counting on. A year or version that wraps to a line's start stays text.
@MainActor
@Suite("Markdown lists starting past 1")
struct MarkdownListStartTests {
    private func blocks(_ text: String) -> [MarkdownBlock.Kind] { MarkdownParser.parse(text[...], base: 0, zoom: 1).map(\.kind) }

    private func paragraph(_ kind: MarkdownBlock.Kind?) -> String? {
        guard case .paragraph(let text) = kind else { return nil }
        return String(text.characters)
    }

    private func list(_ kind: MarkdownBlock.Kind?) -> MarkdownList? {
        guard case .list(let list) = kind else { return nil }
        return list
    }

    /// The owner's case (chat 90abea89): a bold section line, then points 5 and 6.
    static let owners = """
        **A. The tools**
        1. **A gate.** One check.
        2. **A map.** One picture.

        **B. The rule checker**
        5. **A 1-second rule checker.** Reads the rules.
        6. **Rules as tools.** Each one a check.
        """

    @Test func theOwnersSectionBIsAListFrom5() throws {
        let kinds = blocks(Self.owners)
        #expect(kinds.count == 4)
        #expect(paragraph(kinds[0]) == "A. The tools")
        #expect(list(kinds[1])?.start == 1 && list(kinds[1])?.items.count == 2)
        #expect(paragraph(kinds[2]) == "B. The rule checker")
        let b = try #require(list(kinds[3]))
        #expect(b.ordered && b.start == 5 && b.items.count == 2)
        guard case .paragraph(let first) = b.items[0].blocks.first?.kind else { Issue.record("no first point"); return }
        #expect(String(first.characters) == "A 1-second rule checker. Reads the rules.")
    }

    @Test func aColonLeadStartsAListAtItsNumber() {
        let kinds = blocks("Then, in order:\n3. Build it\n")
        #expect(paragraph(kinds.first) == "Then, in order:")
        #expect(list(kinds.last)?.start == 3)
    }

    @Test func countingOnStartsAListWithoutALead() {
        let kinds = blocks("Two more steps\n4. Build\n5. Ship")
        #expect(paragraph(kinds.first) == "Two more steps")
        #expect(list(kinds.last)?.start == 4 && list(kinds.last)?.items.count == 2)
    }

    @Test func aBulletListAfterABoldLineIsAList() {
        let kinds = blocks("**Notes**\n- one\n- two")
        #expect(paragraph(kinds.first) == "Notes")
        #expect(list(kinds.last).map { !$0.ordered && $0.items.count == 2 } == true)
    }

    // MARK: Near misses: prose stays one paragraph

    @Test(arguments: [
        // A year wrapped to the start of a line.
        "We shipped it in\n2026. We moved on after that.",
        // A version: "v0.3." isn't a marker at all.
        "It came out as\nv0.3. Then more followed.",
        // Numbers that don't count on, under no lead.
        "Prices rose in\n2026. A lot.\n2028. Less.",
        // Two bold runs aren't a lead line.
        "**a** and **b**\n5. is the answer here",
        // A number with nothing after it.
        "The total was\n5.",
    ])
    func proseStaysOneParagraph(_ text: String) {
        let kinds = blocks(text)
        #expect(kinds.count == 1)
        #expect(paragraph(kinds.first) != nil)
    }

    @Test func aListFrom1StillInterruptsAsBefore() {
        let kinds = blocks("Steps\n1. One\n2. Two")
        #expect(list(kinds.last)?.start == 1)
    }

    // MARK: Copy keeps the numbers

    @Test func copyingTheSectionKeepsItsNumbers() {
        let source = "**B. The rule checker**\n5. **A 1-second rule checker.** Reads the rules.\n6. **Rules as tools.** Each one a check."
        let id = UUID()
        let copied = SelectionCopy.markdownText(
            source[...], Clip(lo: TextPoint(entry: id, path: [0], offset: 0), hi: TextPoint(entry: id, path: [1, 1, 0], offset: .max)))
        #expect(copied.contains("5. **A 1-second rule checker.** Reads the rules."))
        #expect(copied.contains("6. **Rules as tools.** Each one a check."))
        #expect(!copied.contains("1. "))
    }
}
