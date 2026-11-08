import Foundation

/// Phase 19: a Mac keeps its boxes on the latest release (full grants; the box's welcome says
/// `update`). `host.keep` tells the box that this Mac's "Keep boxes updated" is on or off, after
/// each welcome, so `kore-host status` can say who keeps it current. `host.update{version}` asks
/// the box to update itself from the release now: it refuses while a chat works there, and
/// otherwise downloads, checks and swaps in kore-host as `kore-host update` does, then restarts
/// (links hear `bye restart` and dial again). `host.update.result` answers only a refusal or a
/// failure; a success is the restart.
package enum UpdateWire {
    package static let cap = "update"
    package static let keep = "host.keep"
    package static let update = "host.update"
    package static let result = "host.update.result"

    /// Mac → box: "Keep boxes updated", and the Mac's name for the box to show.
    package struct Keep: Codable, Equatable, Sendable {
        package var t = UpdateWire.keep
        package var on: Bool
        package var by: String

        package init(on: Bool, by: String) {
            self.on = on
            self.by = by
        }
    }

    /// Mac → box: update to `version` (the latest release the Mac knows) or newer.
    package struct Update: Codable, Equatable, Sendable {
        package var t = UpdateWire.update
        package var id: String
        package var version: String
        package var by: String

        package init(id: String, version: String, by: String) {
            self.id = id
            self.version = version
            self.by = by
        }
    }

    /// Box → Mac: why it didn't update. `started` is sent once the update runs; the restart follows.
    package struct Result: Codable, Equatable, Sendable {
        package enum Outcome: String, LenientEnum { case started, busy, current, failed, unknown }
        package var t = UpdateWire.result
        package var id: String
        package var outcome: Outcome
        /// The box's own words, one line.
        package var line: String

        package init(id: String, outcome: Outcome, line: String) {
            self.id = id
            self.outcome = outcome
            self.line = line
        }
    }
}
