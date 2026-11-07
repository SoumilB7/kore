import Foundation

/// What looks like a key or a password, masked in every line the agent channel sends. Best effort:
/// it knows common shapes, and a chat can hold a secret in any other. What it can't recognise goes
/// out as it is, so it's a second line of defence, not what decides who may read a chat.
///
/// It runs on encoded JSON as well as plain text, so no pattern crosses a quote: what it replaces
/// stays inside one string, and the line stays valid JSON.
package enum AgentSecrets {
    package static let mask = "[masked]"

    /// Whole matches are keys. `\b` first, so "task-" isn't "sk-".
    private static let keys = regex(
        #"\b(?:sk-[A-Za-z0-9_-]{16,}"#
            + #"|(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#
            + #"|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#
            + #"|(?:AKIA|ASIA)[0-9A-Z]{16}"#
            + #"|xox[abeprs]-[A-Za-z0-9-]{10,}"#
            + #"|AIza[0-9A-Za-z_-]{30,}"#
            + #"|glpat-[A-Za-z0-9_-]{16,}"#
            + #"|npm_[A-Za-z0-9]{30,}"#
            + #"|hf_[A-Za-z0-9]{30,}"#
            + #"|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#)
    /// To its end, or to the end of the string or text it's in.
    private static let privateKeys = regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[^"\\]|\\.)*?(?:-----END [A-Z ]*PRIVATE KEY-----|(?=")|\z)"#)
    /// What names itself: the name stays, the value goes. An all-digit value is a count. Quotes
    /// around it may be escaped, in a JSON string.
    private static let named = regex(
        #"(?i)((?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key|auth[_-]?key)[A-Za-z0-9_-]{0,32}(?:\\?["'])?\s{0,3}[:=]\s{0,3}(?:\\?["'])?)(?!\d+\b)[^\s"',;\\]{8,}"#)
    private static let bearer = regex(#"(?i)(\bbearer\s+)[A-Za-z0-9._~+/-]{16,}=*"#)
    /// `scheme://user:password@host`.
    private static let inURL = regex(#"([a-z][a-z0-9+.-]*://[^/\s:@"\\]+:)[^/\s@"\\]+(@)"#)

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
