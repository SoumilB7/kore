import Foundation

/// What looks like a key or a password, masked in every line the agent channel sends. Best effort:
/// it knows common shapes, and a chat can hold a secret in any other. What it can't recognise goes
/// out as it is, so it's a second line of defence, not what decides who may read a chat.
///
/// It runs on encoded JSON as well as plain text, so no pattern crosses a quote: what it replaces
/// stays inside one string, and the line stays valid JSON.
package enum AgentSecrets {
    package static let mask = "[masked]"

    /// Where a key can begin: a word's start, or just after an escape in encoded JSON, where the
    /// escape's last letter or digit would hide the boundary (`\n`, `\b`, `\u0007`).
    private static let start = #"(?:(?<=\\[nrtbf])|(?<=\\u[0-9a-fA-F]{4})|\b)"#
    /// Space, or an escaped one in encoded JSON.
    private static let gap = #"(?:\s|\\[nrtf])"#

    /// Whole matches are keys. `start` first, so "task-" isn't "sk-".
    private static let keys = regex(
        start + #"(?:sk-[A-Za-z0-9_-]{16,}"#
            + #"|(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#
            + #"|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#
            + #"|(?:AKIA|ASIA)[0-9A-Z]{16}"#
            + #"|xox[abeprs]-[A-Za-z0-9-]{10,}"#
            + #"|AIza[0-9A-Za-z_-]{30,}"#
            + #"|glpat-[A-Za-z0-9_-]{16,}"#
            + #"|npm_[A-Za-z0-9]{30,}"#
            + #"|hf_[A-Za-z0-9]{30,}"#
            // Bounded, unlike the rest: these can fail after their run, and `-` starts another try.
            + #"|eyJ[A-Za-z0-9_-]{10,512}\.eyJ[A-Za-z0-9_-]{10,16384}\.[A-Za-z0-9_-]{10,2048})"#)
    /// To its end, or to the end of the string or text it's in.
    private static let privateKeys = regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[^"\\]|\\.)*?(?:-----END [A-Z ]*PRIVATE KEY-----|(?=")|\z)"#)
    /// What names itself: the name stays, the value goes. An all-digit value is a count. Quotes
    /// around it may be escaped, in a JSON string.
    private static let named = regex(
        #"(?i)((?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key|auth[_-]?key)[A-Za-z0-9_-]{0,32}(?:\\?["'])?"# + gap + "{0,3}[:=]" + gap + #"{0,3}(?:\\?["'])?)(?!\d+\b)[^\s"',;\\]{8,}"#)
    private static let bearer = regex("(?i)(" + start + "bearer" + gap + #"{1,4})[A-Za-z0-9._~+/-]{16,}=*"#)
    /// `scheme://user:password@host`, found from its `://`: from the scheme's start, a long run
    /// of letters takes quadratic time (27 s for 50 KB).
    private static let inURL = regex(#"(://[^/\s:@"\\]+:)[^/\s@"\\]+(@)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Fixed patterns, checked by the tests: one that didn't compile matches nothing.
        (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }

    package static func mask(_ text: String) -> String {
        guard text.utf8.count >= 8 else { return text }
        var out = text
        for (pattern, template) in [
            (privateKeys, mask), (keys, mask), (bearer, "$1" + mask), (named, "$1" + mask), (inURL, "$1" + mask + "$2"),
        ] {
            let whole = NSRange(out.startIndex..., in: out)
            guard pattern.firstMatch(in: out, range: whole) != nil else { continue }
            out = pattern.stringByReplacingMatches(in: out, range: whole, withTemplate: template)
        }
        return out
    }
}
