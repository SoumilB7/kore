import Testing

@testable import KoreCore

/// `ShellPretty` breaks only where the shell itself would end a command: never inside quotes,
/// substitutions, groups or heredocs, and never changes a character it keeps.
@Suite("Laying out a shell command to read")
struct ShellPrettyTests {
    private func lines(_ command: String, width: Int = 20) -> [String] { ShellPretty.text(command, width: width) }
    private func kinds(_ command: String) -> [(String, ShellPretty.Kind)] {
        ShellPretty.lines(command, width: 500).flatMap { $0 }.filter { $0.text != " " }.map { ($0.text, $0.kind) }
    }

    @Test func shortCommandStaysOnItsLine() {
        #expect(ShellPretty.text("cd src && make | tail -3") == ["cd src && make | tail -3"])
    }

    @Test func breaksAtTopLevelChainsAndPipes() {
        #expect(lines("cd /repo && swift build 2>&1 | tail -20; echo done || true") == [
            "cd /repo", "  && swift build 2>&1", "  | tail -20", "echo done", "  || true",
        ])
    }

    @Test func quotesAndEscapesAreNotOperators() {
        #expect(lines(#"echo 'a && b' "c | d" e\;f \&\& g && ls"#) == [#"echo 'a && b' "c | d" e\;f \&\& g"#, "  && ls"])
    }

    @Test func substitutionsStayWhole() {
        #expect(lines(#"x=$(git log | head -1 && echo "$(date; uptime)") && echo ${x:-a|b}"#) == [
            #"x=$(git log | head -1 && echo "$(date; uptime)")"#, "  && echo ${x:-a|b}",
        ])
        #expect(lines("a=`ls | wc -l` && echo $a") == ["a=`ls | wc -l`", "  && echo $a"])
    }

    @Test func groupsStayWhole() {
        #expect(lines("(cd a && make) && (cd b && make)") == ["(cd a && make)", "  && (cd b && make)"])
    }

    @Test func heredocBodyIsLeftAlone() {
        let command = "cat <<'EOF' | wc -l && echo ok\nit's a | b && c\n  indented; too\nEOF\necho after"
        #expect(lines(command) == ["cat <<'EOF'", "  | wc -l", "  && echo ok", "it's a | b && c", "  indented; too", "EOF", "echo after"])
    }

    @Test func heredocInsideSubstitutionKeepsItsApostrophes() {
        let command = "git add . && git commit -m \"$(cat <<'EOF'\nIt's fixed (mostly)\nEOF\n)\" && git push"
        let text = lines(command).joined(separator: "\n")
        #expect(text == "git add .\n  && git commit -m \"$(cat <<'EOF'\nIt's fixed (mostly)\nEOF\n)\"\n  && git push")
    }

    @Test func loopAndIfBodiesGetTheirOwnLines() {
        #expect(lines("for f in *.swift; do swift-format \"$f\" | head; done") == [
            "for f in *.swift; do", "  swift-format \"$f\"", "    | head", "done",
        ])
        #expect(lines("if [ -f a ]; then echo yes; elif [ -f b ]; then echo b; else echo no; fi") == [
            "if [ -f a ]; then", "  echo yes", "elif [ -f b ]; then", "  echo b", "else", "  echo no", "fi",
        ])
    }

    @Test func caseIsLeftOnItsLine() {
        #expect(lines("case $x in a|b) echo 1;; *) echo 2;; esac && ls") == ["case $x in a|b) echo 1;; *) echo 2;; esac", "  && ls"])
    }

    @Test func keepsWrittenLineBreaks() {
        #expect(lines("curl -s \\\n  -H 'X: y' url && ls") == ["curl -s \\", "  -H 'X: y' url", "  && ls"])
        #expect(lines("make\nmake test") == ["make", "make test"])
    }

    @Test func redirectionsAndBackgroundJobs() {
        #expect(lines("server >log 2>&1 & sleep 1 && curl localhost") == ["server >log 2>&1 &", "sleep 1", "  && curl localhost"])
    }

    @Test func colours() {
        let pieces = kinds(#"FOO=1 git commit --amend -m "msg $HOME" && echo ${X} # done"#)
        #expect(pieces.map(\.0) == ["FOO=1", "git", "commit", "--amend", "-m", "\"msg ", "$HOME", "\"", "&&", "echo", "${X}", "# done"])
        #expect(pieces.map(\.1) == [.variable, .command, .plain, .flag, .flag, .string, .variable, .string, .op, .command, .variable, .comment])
        #expect(kinds("make 2>&1").map(\.1) == [.command, .op, .op])
        #expect(kinds("for x in a; do ls; done").map(\.1) == [.keyword, .plain, .plain, .plain, .op, .keyword, .command, .op, .keyword])
    }

    @Test func unterminatedInputNeverHangs() {
        for command in ["echo 'open", "echo \"open $(", "x=${", "cat <<EOF\nbody", "a \\", "$(a \\", "echo `a \\", ")", "(((", "`"] {
            #expect(!lines(command).isEmpty)
        }
    }
}
