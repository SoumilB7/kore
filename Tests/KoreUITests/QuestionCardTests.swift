import Foundation
import KoreCore
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
        let picked: [String: Set<String>] = ["Which layout?": ["Grid"], "Which colours?": ["Blue", "Red"]]
        #expect(
            QuestionCard.answers(questions, picked: picked, other: ["Which colours?": "  Green \n"])
                == ["Which layout?": ["Grid"], "Which colours?": ["Red", "Blue", "Green"]])
        #expect(QuestionCard.complete(questions, picked: picked, other: [:]))
        #expect(!QuestionCard.complete(questions, picked: picked, other: ["Which colours?": " "]))
        #expect(!QuestionCard.complete(questions, picked: ["Which layout?": ["Grid"]], other: [:]))
        // Claude gets each answer as one string, joined as before.
        #expect(
            QuestionCard.answers(questions, picked: picked, other: ["Which colours?": "Green"]).mapValues { $0.joined(separator: ", ") }
                == ["Which layout?": "Grid", "Which colours?": "Red, Blue, Green"])
    }
}
