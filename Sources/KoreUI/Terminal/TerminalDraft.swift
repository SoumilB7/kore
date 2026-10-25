import Foundation

/// Installs a draft through zsh's line editor, never through PTY input. Even multiline text,
/// substitutions and control bytes remain editable BUFFER contents until the person presses
/// Return. Startup files are proxied from the user's original ZDOTDIR; none are modified.
final class TerminalDraft {
    let directory: URL
    let original: String?

    init(_ text: String, environment: [String: String]) throws {
        original = environment["ZDOTDIR"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kore-terminal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let draft = directory.appendingPathComponent("draft")
            try Data(text.utf8).write(to: draft, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draft.path)
            for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                var script = #"""
                if [[ $KORE_TERMINAL_ORIGINAL_SET == 1 ]]; then
                    export ZDOTDIR=$KORE_TERMINAL_ORIGINAL
                else
                    unset ZDOTDIR
                fi
                [[ -r "$KORE_TERMINAL_ORIGINAL/FILE" ]] && source "$KORE_TERMINAL_ORIGINAL/FILE"
                """#.replacingOccurrences(of: "FILE", with: file) + "\n"
                if file != ".zlogin" {
                    script += #"""
                    export KORE_TERMINAL_ORIGINAL_SET=${+ZDOTDIR}
                    export KORE_TERMINAL_ORIGINAL=${ZDOTDIR:-$HOME}
                    export ZDOTDIR=$KORE_TERMINAL_STARTUP
                    """# + "\n"
                }
                if file == ".zshrc" {
                    script += #"""
                    autoload -Uz add-zle-hook-widget
                    function _kore_terminal_draft() {
                        BUFFER=$(< "$KORE_TERMINAL_DRAFT_FILE")
                        CURSOR=${#BUFFER}
                        unset KORE_TERMINAL_DRAFT_FILE
                        add-zle-hook-widget -d line-init _kore_terminal_draft
                        unfunction _kore_terminal_draft
                    }
                    add-zle-hook-widget line-init _kore_terminal_draft
                    """# + "\n"
                }
                if file == ".zlogin" {
                    script += "unset KORE_TERMINAL_STARTUP KORE_TERMINAL_ORIGINAL KORE_TERMINAL_ORIGINAL_SET\n"
                }
                try script.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func apply(to environment: inout [String: String]) {
        environment["KORE_TERMINAL_DRAFT_FILE"] = directory.appendingPathComponent("draft").path
        environment["KORE_TERMINAL_STARTUP"] = directory.path
        environment["KORE_TERMINAL_ORIGINAL_SET"] = original == nil ? "0" : "1"
        environment["KORE_TERMINAL_ORIGINAL"] = original ?? environment["HOME"] ?? NSHomeDirectory()
        environment["ZDOTDIR"] = directory.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
