import Foundation
import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// The question card's data (question-card.html, B "Steps"): the CLIs' `header` and `preview`
/// read in, tab names, and the answers sent back in the format the CLIs always got.
@MainActor
@Suite("Question card")
struct QuestionCardTests {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func claudeHeadersAndPreviews() throws {
        let input = try json(
            #"{"questions":[{"question":"Which layout?","header":"Layout","multiSelect":false,"options":[{"label":"Tabs","description":"One pane","preview":"A │ B"},{"label":"List","description":"One scroll","preview":""}]},{"question":"Which colours?","multiSelect":true,"options":[{"label":"Red","description":""}]}]}"#)
        let questions = ClaudeTranslator.questions(input)
        #expect(questions.map(\.id) == ["Which layout?", "Which colours?"])
        #expect(questions.map(\.header) == ["Layout", ""])
        #expect(questions[0].options.map(\.preview) == ["A │ B", nil])
        #expect(questions.map(\.multiple) == [false, true])
        // Claude always takes a typed answer.
        #expect(questions.allSatisfy { $0.other })
    }

    @Test func codexHeadersAndOther() throws {
        let asked = try json(
            #"{"id":"color","header":"Colour","question":"Which colour?","isOther":false,"isSecret":false,"options":[{"label":"Red","description":"warm"}]}"#)
        let question = CodexTranslator.question(asked)
        #expect(question.id == "color" && question.header == "Colour" && question.text == "Which colour?")
        #expect(!question.other)
        #expect(question.options.map(\.label) == ["Red"])
        // isOther not sent: Other shown; no options: only a typed answer.
        let open = CodexTranslator.question(try json(#"{"id":"a","question":"Why?","options":[{"label":"x","description":""}]}"#))
        #expect(open.other)
        let free = CodexTranslator.question(try json(#"{"id":"b","question":"Name?","isOther":false,"isSecret":true,"options":null}"#))
        #expect(free.other && free.secret && free.options.isEmpty)
    }

    @Test func tabNames() {
        func q(_ text: String, header: String = "") -> Approval.Question { .init(id: text, text: text, header: header, options: []) }
        #expect(q("Anything", header: " Sync ").tabName(0) == "Sync")
        #expect(q("Keep a Reset button on each section?").tabName(2) == "Keep a Reset")
        #expect(q("Which?").tabName(0) == "Which")
        #expect(q("").tabName(1) == "Q2")
        #expect(q("Supercalifragilisticexpialidocious words").tabName(0) == "Supercalifragilisticexpialidocious")
    }

    /// Each question's picks in the options' order, then what was typed; an Other left empty
    /// leaves its question unanswered.
    @Test func answersKeepTheirFormat() {
        let questions = [
            Approval.Question(id: "Which layout?", text: "Which layout?", options: [.init(label: "Grid", description: ""), .init(label: "List", description: "")]),
            Approval.Question(
                id: "Which colours?", text: "Which colours?",
                options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")], multiple: true),
        ]
        var picks = QuestionPicks(options: ["Which layout?": ["Grid"], "Which colours?": ["Blue", "Red"]])
        #expect(picks.complete(questions))
        picks.pickOther(in: questions[1])
        picks.typed["Which colours?"] = " "
        #expect(!picks.complete(questions))
        picks.typed["Which colours?"] = "  Green \n"
        #expect(picks.answers(questions) == ["Which layout?": ["Grid"], "Which colours?": ["Red", "Blue", "Green"]])
        #expect(!QuestionPicks(options: ["Which layout?": ["Grid"]]).complete(questions))
        // Claude gets each answer as one string, joined as before.
        #expect(picks.answers(questions).mapValues { $0.joined(separator: ", ") } == ["Which layout?": "Grid", "Which colours?": "Red, Blue, Green"])
    }

    /// One question of each CLI's shape: Claude's (its text its id, Other always there) and
    /// Codex's (an id of its own, isOther).
    private func oneOf(_ cli: String, multiple: Bool = false) throws -> Approval.Question {
        if cli == "claude" {
            return try #require(
                ClaudeTranslator.questions(
                    json(#"{"questions":[{"question":"Which layout?","header":"Layout","multiSelect":\#(multiple),"options":[{"label":"Tabs","description":""},{"label":"Sidebar","description":""}]}]}"#)
                ).first)
        }
        return CodexTranslator.question(
            try json(#"{"id":"layout","header":"Layout","question":"Which layout?","isOther":true,"options":[{"label":"Tabs","description":""},{"label":"Sidebar","description":""}]}"#))
    }

    /// A one-of holds one pick: an option then Other leaves Other; Other (typed into) then an
    /// option leaves the option, and the words stay for Other but aren't sent.
    @Test(arguments: ["claude", "codex"]) func oneOfHoldsOnePick(_ cli: String) throws {
        let question = try oneOf(cli)
        #expect(question.other && !question.multiple)
        let id = question.id
        var picks = QuestionPicks()

        picks.pick("Tabs", in: question)
        let opened = picks.pickOther(in: question)
        #expect(opened)
        #expect(picks.options[id] == [] && picks.other == [id])
        #expect(!picks.answered(question))
        picks.typed[id] = "Tabs in a sidebar"
        #expect(picks.answers([question]) == [id: ["Tabs in a sidebar"]])

        picks.pick("Sidebar", in: question)
        #expect(picks.options[id] == ["Sidebar"] && picks.other.isEmpty)
        #expect(picks.typed[id] == "Tabs in a sidebar")
        #expect(picks.answered(question) && picks.text(question) == nil)
        #expect(picks.answers([question]) == [id: ["Sidebar"]])

        // Other again: the words back, the option gone.
        let again = picks.pickOther(in: question)
        #expect(again)
        #expect(picks.options[id] == [] && picks.answers([question]) == [id: ["Tabs in a sidebar"]])
        // Other unpicked: nothing picked, nothing sent.
        let closed = picks.pickOther(in: question)
        #expect(!closed)
        #expect(!picks.answered(question) && picks.answers([question]) == [id: []])
    }

    /// An any-of (Claude's multiSelect; Codex has none) keeps Other as one more box: options and
    /// Other's words go together.
    @Test func anyOfKeepsOtherBeside() throws {
        let question = try oneOf("claude", multiple: true)
        #expect(question.multiple)
        let id = question.id
        var picks = QuestionPicks()
        let opened = picks.pickOther(in: question)
        #expect(opened)
        picks.typed[id] = "Window size"
        picks.pick("Sidebar", in: question)
        picks.pick("Tabs", in: question)
        #expect(picks.other == [id] && picks.answers([question]) == [id: ["Tabs", "Sidebar", "Window size"]])
        picks.pickOther(in: question)
        #expect(picks.answers([question]) == [id: ["Tabs", "Sidebar"]])
    }

    /// A question with no options takes only words, Other or not.
    @Test func noOptionsSendsTheWords() {
        let question = Approval.Question(id: "name", text: "Name?", options: [])
        var picks = QuestionPicks()
        #expect(!picks.answered(question))
        picks.typed["name"] = " Kore "
        #expect(picks.answered(question) && picks.answers([question]) == ["name": ["Kore"]])
    }
}
