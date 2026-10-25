import Testing

@testable import KoreUI

/// The "/word" at the caret the slash menu filters by, and the command chip's way to and from
/// the text the CLI is sent.
@Suite("Slash commands in the composer")
struct SlashCommandTests {
    static let review = SlashCommand(name: "review", description: "", hint: "", kind: .command)
    static let pdf = SlashCommand(name: "pdf", description: "", hint: "", kind: .skill)

    func token(_ marked: String, skills: Bool = false) -> SlashToken? {
        let caret = marked.firstIndex(of: "|") ?? marked.endIndex
        var text = marked
        text.remove(at: caret)
        return SlashToken(in: text, caret: text.index(text.startIndex, offsetBy: marked.distance(from: marked.startIndex, to: caret)), skills: skills)
    }

    @Test func findsTheWordAtTheCaret() {
        #expect(token("/|")?.query == "")
        #expect(token("/Re|")?.query == "re")
        #expect(token("fix this /co|")?.query == "co")
        #expect(token("fix this\n/co|")?.query == "co")
        #expect(token("/co|mpact")?.query == "co")
    }

    @Test func leavesPathsAndPlainWordsAlone() {
        #expect(token("see /usr/bi|") == nil)
        #expect(token("a/b|") == nil)
        #expect(token("fix this |") == nil)
        #expect(token("$pd|") == nil)
        #expect(token("$pd|", skills: true)?.sigil == "$")
    }

    @Test func aPickReplacesTheWordAndKeepsOneSpace() throws {
        let text = "fix this /co and that"
        let caret = text.index(text.startIndex, offsetBy: 12)
        let found = try #require(SlashToken(in: text, caret: caret, skills: true))
        #expect(found.replacing(in: text, with: "") == ("fix this and that", 9))
        #expect(found.replacing(in: text, with: "$pdf ") == ("fix this $pdf and that", 14))
        let start = try #require(SlashToken(in: "/", caret: "/".endIndex, skills: false))
        #expect(start.replacing(in: "/", with: "") == ("", 0))
    }

    @Test func theChipGoesFirstInTheMessage() {
        #expect(Chat.message(command: Self.review, draft: "  the login fix \n") == "/review the login fix")
        #expect(Chat.message(command: Self.review, draft: "") == "/review")
        #expect(Chat.message(command: nil, draft: " hi ") == "hi")
    }

    @Test func aSentMessageSplitsBackIntoChipAndText() {
        let commands = [Self.review, Self.pdf]
        #expect(Chat.split("/review the login fix", commands: commands) == (Self.review, "the login fix"))
        #expect(Chat.split("/review", commands: commands) == (Self.review, ""))
        #expect(Chat.split("/usr/bin is missing", commands: commands) == (nil, "/usr/bin is missing"))
        #expect(Chat.split("/pdf this", commands: commands) == (nil, "/pdf this"))
        #expect(Chat.split("say /review", commands: commands) == (nil, "say /review"))
    }

    @Test func summariesSayWhatACommandDoesInAFewWords() {
        let cases = [
            ("Pre-commit/ship code review: Codex default; optional Claude or Pi. (user)", "Pre-commit/ship code review"),
            ("Logging best practices focused on wide events (canonical log lines) for powerful debugging and analytics", "Logging best practices"),
            ("Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize", "Deep research harness"),
            ("(human-resources) Analyze compensation — benchmarking, band placement, and equity modeling.", "Analyze compensation"),
            ("(human-resources) Draft an offer letter with comp details and terms. Use when a candidate is ready.", "Draft an offer letter"),
            ("(human-resources) Create structured interview plans with competency-based questions and scorecards.", "Create structured interview plans"),
            ("Generate an onboarding checklist and first-week plan for a new hire.", "Generate an onboarding checklist"),
            ("Clear conversation history but keep a summary in context. Optional: /compact [instructions]", "Clear conversation history"),
            ("Set the model for this session", "Set the model for this session"),
            ("Plan limits", "Plan limits"),
            ("", ""),
        ]
        for (description, summary) in cases {
            #expect(SlashCommand.summary(of: description) == summary, "\(description)")
        }
    }
}

