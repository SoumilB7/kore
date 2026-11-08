import Foundation

/// The Tailscale app capability Kore reads from a peer's WhoIs `CapMap`
/// (`{"<KoreCapDomain>": [{"v":1,"abilities":["read","ask"]}]}`): a tagged node is let in only
/// with one, and then at most read+ask. Parsing is strict: any other key, version, type, unknown
/// or repeated ability makes the whole capability absent.
package let KoreCapDomain = "kore.invalid/cap/kore" // PLACEHOLDER: the owner hasn't picked Kore's domain (plan §11 q2).

package enum AppCap {
    /// The most a tagged node gets, whatever its grant says.
    package static let taggedCap: Ability = [.read, .ask]

    /// The abilities the grants under Kore's key give, or nil when there's no valid one. Several
    /// grants (several ACL rules) are joined; one malformed grant voids them all.
    package static func abilities(capMap: [String: [JSONValue]]?, tagged: Bool) -> Ability? {
        guard let grants = capMap?[KoreCapDomain], !grants.isEmpty else { return nil }
        var out: Ability = []
        for grant in grants {
            guard let one = parse(grant) else { return nil }
            out.formUnion(one)
        }
        if tagged { out = out.effective.intersection(taggedCap) }
        return out.isEmpty ? nil : out
    }

    /// One `{"v":1,"abilities":[…]}`.
    package static func parse(_ grant: JSONValue) -> Ability? {
        guard case .object(let fields) = grant, Set(fields.keys) == ["v", "abilities"],
              case .int(1) = fields["v"], case .array(let list) = fields["abilities"], !list.isEmpty else { return nil }
        var names: [String] = []
        for item in list {
            guard case .string(let name) = item else { return nil }
            names.append(name)
        }
        return Ability(names: names)
    }
}
