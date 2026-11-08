import Foundation
import KoreTrust
import LinkProtocol

/// What a grant lets its client do: read only, act in chats, or also run the accounts.
package enum GrantControl: String, Codable, Sendable, CaseIterable, Comparable {
    case watch, act, full

    /// Phase 18: a device's abilities as the checks per command know them: run → full,
    /// read+ask → act, read → watch; nil for none.
    package init?(_ abilities: Ability) {
        let held = abilities.effective
        if held.contains(.run) {
            self = .full
        } else if held.contains(.ask) {
            self = .act
        } else if held.contains(.read) {
            self = .watch
        } else {
            return nil
        }
    }

    /// The abilities a grant's Mac enrolls with (the upgrade): full → run, act → read+ask,
    /// watch → read.
    package var abilities: Ability {
        switch self {
        case .full: [.read, .ask, .run]
        case .act: [.read, .ask]
        case .watch: [.read]
        }
    }

    package static func < (a: GrantControl, b: GrantControl) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One allowed client: `kore-host allow <name>` writes it, `revoke` deletes it. The secret keys
/// the hello's proof and never leaves the box.
package struct Grant: Codable, Sendable, Equatable {
    package var v = 1
    package var name: String
    package var socket: String
    package var secret: String
    package var control: GrantControl
    package var created: Int
    /// Phase 18: the device the grant's Mac enrolled as (`attach --proto 2`, once). From then on
    /// its links count as that device's (dedupe, replace, owners), and a revoke of the device
    /// ends them too.
    package var device: UUID?
    /// When the grant stops working (seconds since 1970): 30 days after its Mac's upgrade, so the
    /// SSH route keeps working while every Mac updates.
    package var expires: Int?

    package init(name: String, socket: String, secret: String, control: GrantControl, created: Int, device: UUID? = nil, expires: Int? = nil) {
        self.name = name
        self.socket = socket
        self.secret = secret
        self.control = control
        self.created = created
        self.device = device
        self.expires = expires
    }

    /// Past its `expires`.
    package func expired(at now: Date) -> Bool { expires.map { Double($0) <= now.timeIntervalSince1970 } ?? false }

    /// How long an upgraded grant keeps working.
    package static let upgradeGrace: TimeInterval = 30 * 86400

    /// Letters, digits and `._-`, up to 64: a name that is a file name.
    package static func valid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }
}

/// The grants folder (0700, each file 0600).
package struct GrantStore: Sendable {
    package let folder: URL

    package init(_ folder: URL) { self.folder = folder }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name + ".json") }

    package func load(_ name: String) -> Grant? {
        guard Grant.valid(name), let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(Grant.self, from: data)
    }

    /// The grant as its file says now, for a connection that proved `secret`: nil once it's
    /// revoked or issued again (a new secret). Read on every command, so `revoke` and a lowered
    /// `--control` take effect at the next one, with no signal to the daemon.
    package func current(_ name: String, secret: String, at time: Date = Date()) -> Grant? {
        guard let now = load(name), now.secret == secret, !now.expired(at: time) else { return nil }
        return now
    }

    /// Writes the grant back (an upgrade's `device` and `expires`).
    package func save(_ grant: Grant) throws {
        guard Grant.valid(grant.name) else { throw GrantError.badName }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try HostPaths.privateFile(encoder.encode(grant), to: file(grant.name))
    }

    package func all() -> [Grant] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted().compactMap(load)
    }

    /// A new grant with a fresh secret, replacing one of the same name.
    @discardableResult
    package func allow(_ name: String, control: GrantControl, socket: URL) throws -> Grant {
        guard Grant.valid(name) else { throw GrantError.badName }
        let grant = Grant(
            name: name, socket: socket.path, secret: LinkProof.random(32), control: control,
            created: Int(Date().timeIntervalSince1970))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try HostPaths.privateFile(encoder.encode(grant), to: file(name))
        return grant
    }

    /// Whether there was one.
    @discardableResult
    package func revoke(_ name: String) -> Bool {
        guard Grant.valid(name) else { return false }
        return (try? FileManager.default.removeItem(at: file(name))) != nil
    }
}

package enum GrantError: Error, CustomStringConvertible {
    case badName
    package var description: String { "A grant's name is letters, digits and ._- (up to 64)." }
}
