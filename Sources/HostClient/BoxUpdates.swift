import Foundation
import KoreCore
import LinkProtocol
import Observation

/// "Keep boxes updated" (phase 19), on by default: a box on an older kore-host than the latest
/// release this Mac found is asked to update itself (`host.update`) once no chat works there. The
/// box downloads and checks the release, swaps itself in and restarts; links come back by
/// themselves. A box hears the setting (`host.keep`) at each link-up, for its `kore-host status`.
/// The SSH Update (BoxSetup with a BoxHostBuild) stays the dev Mac's way.
@MainActor @Observable
package final class BoxUpdates {
    package static let shared = BoxUpdates()
    package static let keepKey = "keepBoxesUpdated"
    /// A box asked for a version isn't asked again for it sooner than this.
    package static let retryAfter: TimeInterval = 30 * 60

    let defaults: UserDefaults
    /// The latest release this Mac found (Updater's check); nil until one was found.
    package var latest: String?
    @ObservationIgnored package var now: () -> Date = Date.init
    /// What this Mac is called on a box ("Soumil's MacBook Air").
    @ObservationIgnored package var macName: () -> String = { BoxUpdates.computerName() }
    /// Each box's last ask: the version and when.
    @ObservationIgnored private(set) var asked: [String: (version: String, at: Date)] = [:]

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The setting, kept in this Mac's defaults.
    package var keep: Bool {
        get {
            access(keyPath: \.keep)
            return defaults.object(forKey: Self.keepKey) as? Bool ?? true
        }
        set { withMutation(keyPath: \.keep) { defaults.set(newValue, forKey: Self.keepKey) } }
    }

    /// What a link to a box knows: its alias, its kore-host version and caps, and whether a chat
    /// works there. `send` posts one message on the link.
    package struct Box {
        package var alias: String
        package var version: String
        package var caps: [String]
        package var working: Bool
        package var send: @MainActor (Data) -> Bool

        package init(alias: String, version: String, caps: [String], working: Bool, send: @escaping @MainActor (Data) -> Bool) {
            self.alias = alias
            self.version = version
            self.caps = caps
            self.working = working
            self.send = send
        }
    }

    /// A full link came up: the box hears the setting, then is asked to update when it should.
    package func linkedUp(_ box: Box) {
        guard box.caps.contains(UpdateWire.cap) else { return }
        _ = box.send(StreamWire.encode(UpdateWire.Keep(on: keep, by: macName())))
        consider(box)
    }

    /// The box's chats changed (a turn ended): asked when it should be.
    package func consider(_ box: Box) {
        guard let version = due(box) else { return }
        guard box.send(StreamWire.encode(UpdateWire.Update(id: "upd-\(UUID().uuidString.prefix(8))", version: version, by: macName()))) else { return }
        asked[box.alias] = (version, now())
        HostLog.note(box.alias, "update asked", "\(box.version) → \(version)")
    }

    /// The version to ask `box` for now, or nil: the setting is on, the box takes `host.update`,
    /// is older than the latest release, no chat works there, and it wasn't just asked.
    package func due(_ box: Box) -> String? {
        guard keep, let latest, box.caps.contains(UpdateWire.cap), !box.working else { return nil }
        guard ReleaseManifest.newer(latest, than: box.version) else { return nil }
        if let last = asked[box.alias], last.version == latest, now().timeIntervalSince(last.at) < Self.retryAfter { return nil }
        return latest
    }

    /// The box's answer when it didn't update: busy waits for the next idle chat, the rest for the retry.
    package func answered(_ alias: String, _ result: UpdateWire.Result) {
        HostLog.note(alias, "update \(result.outcome.rawValue)", result.line)
        if result.outcome == .busy { asked[alias] = nil }
    }

    /// This Mac's name as people know it.
    nonisolated package static func computerName() -> String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}

extension BoxUpdates.Box {
    /// A linked box as its connection knows it; nil before its welcome.
    @MainActor
    package init?(_ connection: HostConnection) {
        guard let version = connection.hostVersion else { return nil }
        self.init(
            alias: connection.alias, version: version, caps: connection.caps,
            working: connection.chats.values.contains { $0.running || $0.state == .working },
            send: { [weak connection] in connection?.post($0) ?? false })
    }
}
