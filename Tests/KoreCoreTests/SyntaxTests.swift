import Foundation
import Testing

@testable import KoreCore

/// The editor's scanners for data files, `.env`, diffs and code fences: the kind each token gets.
@Suite("syntax: data, .env, diffs, fences")
struct SyntaxTests {
    /// Each token's text and kind, in order.
    private func tokens(_ language: Language, _ line: String, from state: Language.State = .normal) -> [String] {
        let units = Array(line.utf16)
        var tokens: [Language.Token] = []
        _ = language.scan(units, from: state, into: &tokens)
        return tokens.map { "\(String(utf16CodeUnits: Array(units[$0.range]), count: $0.range.count))=\($0.kind)" }
    }

    private func end(_ language: Language, _ line: String, from state: Language.State = .normal) -> Language.State {
        language.endState(Array(line.utf16), from: state)
    }

    @Test func jsonKeysAreKeysAndValuesStrings() {
        #expect(tokens(.json, #"{"name": "Ada", "n": 3, "ok": true}"#) == [
            "{=punctuation", #""name"=key"#, ":=punctuation", #""Ada"=string"#, ",=punctuation", #""n"=key"#, ":=punctuation",
            "3=number", ",=punctuation", #""ok"=key"#, ":=punctuation", "true=constant", "}=punctuation",
        ])
    }

    @Test func yamlKeysPlainValuesDashesAnchorsAndAliases() {
        #expect(tokens(.yaml, "name: Kore app # the name") == ["name=key", ":=punctuation", "Kore app=string", "# the name=comment"])
        #expect(tokens(.yaml, "  - item one") == ["-=punctuation", "item one=string"])
        #expect(tokens(.yaml, "- id: 4") == ["-=punctuation", "id=key", ":=punctuation", "4=number"])
        #expect(tokens(.yaml, "base: &defaults") == ["base=key", ":=punctuation", "&defaults=attribute"])
        #expect(tokens(.yaml, "dev: *defaults") == ["dev=key", ":=punctuation", "*defaults=attribute"])
        #expect(tokens(.yaml, "on: true") == ["on=key", ":=punctuation", "true=constant"])
        #expect(tokens(.yaml, "url: http://a.b:80/x") == ["url=key", ":=punctuation", "http://a.b:80/x=string"])
        #expect(tokens(.yaml, #""quoted key": 'v'"#) == [#""quoted key"=key"#, ":=punctuation", "'v'=string"])
        #expect(tokens(.yaml, "---") == ["---=punctuation"])
    }

    @Test func tomlTablesAreHeadingsAndNamesKeys() {
        #expect(tokens(.toml, "[package]") == ["[package]=heading"])
        #expect(tokens(.toml, "[[bin]] # one") == ["[[bin]]=heading", "# one=comment"])
        #expect(tokens(.toml, #"name = "kore""#) == ["name=key", #""kore"=string"#])
        #expect(tokens(.toml, "a.b-c = 1") == ["a.b-c=key", "1=number"])
        #expect(tokens(.ini, "[user]") == ["[user]=heading"])
        #expect(tokens(.ini, "editor = vim") == ["editor=key"])
    }

    @Test func cssPropertiesAreKeys() {
        #expect(tokens(.css, "  color: #fff;").prefix(3) == ["color=key", ":=punctuation", "#fff=number"])
    }

    @Test func dotenvKeysExportCommentsAndSecretValues() {
        let env = Language.dotenv
        #expect(tokens(env, "# local only") == ["# local only=comment"])
        #expect(tokens(env, "API_KEY=sk-123") == ["API_KEY=key", "==punctuation", "sk-123=secret"])
        #expect(tokens(env, "export DB_URL = postgres://x # dev") == [
            "export=keyword", "DB_URL=key", "==punctuation", "postgres://x=secret", "# dev=comment",
        ])
        #expect(tokens(env, #"TOKEN="a b""#) == ["TOKEN=key", "==punctuation", #""=punctuation"#, "a b=secret", #""=punctuation"#])
        #expect(tokens(env, "EMPTY=") == ["EMPTY=key", "==punctuation"])
        // A quoted value over several lines stays secret to its closing quote.
        let open = end(env, #"KEY="-----BEGIN"#)
        #expect(open == .string(quote: .quote, triple: false))
        #expect(tokens(env, "abc", from: open) == ["abc=secret"])
        #expect(tokens(env, #"END" # c"#, from: open) == ["END=secret", #""=punctuation"#, "# c=comment"])
    }

    @Test func dotenvFilesUseTheDotenvScanner() {
        for name in [".env", ".env.local", ".env.production", "app.env"] {
            #expect(Language.of(URL(fileURLWithPath: "/r/" + name)) == .dotenv, "\(name)")
        }
        #expect(Language.of(URL(fileURLWithPath: "/r/setup.cfg")) == .ini)
    }

    @Test func diffLinesAddedRemovedAndHunks() {
        #expect(tokens(.diff, "@@ -1,2 +1,3 @@") == ["@@ -1,2 +1,3 @@=heading"])
        #expect(tokens(.diff, "+let a = 1") == ["+let a = 1=inserted"])
        #expect(tokens(.diff, "-let a = 0") == ["-let a = 0=removed"])
        #expect(tokens(.diff, "--- a/x.swift") == ["--- a/x.swift=keyword"])
        #expect(tokens(.diff, "+++ b/x.swift") == ["+++ b/x.swift=keyword"])
        #expect(tokens(.diff, " context").isEmpty)
        #expect(Language.of(URL(fileURLWithPath: "/r/fix.patch")) == .diff)
    }

    @Test func fenceNamesAndAliases() {
        let cases: [(String, Language)] = [
            ("sh", .shell), ("bash", .shell), ("zsh", .shell), ("ts", .typescript), ("tsx", .typescript), ("py", .python),
            ("yml", .yaml), ("env", .dotenv), ("dotenv", .dotenv), ("diff", .diff), ("patch", .diff), ("swift", .swift),
            ("JSON", .json), ("rust", .rust), ("js title=\"a\"", .javascript), ("", .plain), ("klingon", .plain),
        ]
        for (fence, language) in cases { #expect(Language.named(fence) == language, "\(fence)") }
    }
}
