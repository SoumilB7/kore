import Foundation

// What a device is and what it may do on another (phase 18 §1 "Trust"). The node model
// (`HostClient/Node.swift`) and the device book share these.

package enum NodeKind: String, Codable, Sendable, CaseIterable {
    case mac, box, phone
}

/// What a node may do on this one: **read** (snapshot, tx, attention, history, files, diff, git
/// status), **ask** (read + sends within mode, plain answers, stop, drafts, rename, create in known
/// folders), **run** (everything). Written as names (`["read","ask"]`), the form the app capability
/// and the Kotlin side use.
package struct Ability: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let read = Ability(rawValue: 1 << 0)
    package static let ask = Ability(rawValue: 1 << 1)
    package static let run = Ability(rawValue: 1 << 2)

    package static let named: [(String, Ability)] = [("read", .read), ("ask", .ask), ("run", .run)]

    package var names: [String] { Self.named.filter { contains($0.1) }.map(\.0) }

    /// The set the names spell; nil for an unknown or repeated name.
    package init?(names: [String]) {
        var out: Ability = []
        for name in names {
            guard let one = Self.named.first(where: { $0.0 == name })?.1, !out.contains(one) else { return nil }
            out.insert(one)
        }
        self = out
    }

    /// What the set allows once each ability's lower ones are counted: run holds ask and read,
    /// ask holds read.
    package var effective: Ability {
        if contains(.run) { return [.read, .ask, .run] }
        if contains(.ask) { return [.read, .ask] }
        return self
    }

    /// Whether the set allows everything `needed` names.
    package func allows(_ needed: Ability) -> Bool { effective.isSuperset(of: needed) }
}

extension Ability: Codable {
    package init(from decoder: any Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        guard let set = Ability(names: names) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "abilities \(names)"))
        }
        self = set
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}
