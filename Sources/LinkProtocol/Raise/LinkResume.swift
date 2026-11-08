import Foundation
import KoreTrust

/// A KoreNet client's resume cursors (phase 18 §1 "Resume"), the first message after the welcome:
/// `{"attn":{"aid":N},"snapshot":{"rev":R}}`. A server sends the deltas since `rev` when it kept
/// what that client was sent (else a snapshot), and the turn ends after `aid`.
package enum LinkResume {
    /// The last attention id the client saw.
    package static func aid(_ cursors: [String: JSONValue]?) -> Int? { int(cursors?["attn"], "aid") }

    /// The snapshot rev the client holds.
    package static func rev(_ cursors: [String: JSONValue]?) -> Int? { int(cursors?["snapshot"], "rev") }

    private static func int(_ value: JSONValue?, _ key: String) -> Int? {
        guard case .object(let fields)? = value else { return nil }
        switch fields[key] {
        case .int(let n)?: return n >= 0 ? Int(n) : nil
        case .double(let d)? where d >= 0 && d == d.rounded() && d < 1e15: return Int(d)
        default: return nil
        }
    }

    /// The cursors as a client sends them.
    package static func cursors(aid: Int?, rev: Int?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let aid { out["attn"] = .object(["aid": .int(Int64(aid))]) }
        if let rev { out["snapshot"] = .object(["rev": .int(Int64(rev))]) }
        return out
    }
}
