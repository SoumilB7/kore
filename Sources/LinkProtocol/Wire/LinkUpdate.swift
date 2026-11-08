import Foundation

/// Phase 19: a Mac keeps its boxes on the latest release (full grants; the box's welcome says
/// `update`). `host.keep` tells the box that this Mac's "Keep boxes updated" is on or off, after
/// each welcome, so `kore-host status` can say who keeps it current. `host.update{version}` asks
/// the box to update itself from the release now: it refuses while a chat works there, and
/// otherwise downloads, checks and swaps in kore-host as `kore-host update` does, then restarts
/// (links hear `bye restart` and dial again). `host.update.result` answers only a refusal or a
/// failure; a success is the restart.
///
/// A box that can't reach GitHub answers `offline` with its asset's name: the Mac downloads the
/// release itself, checks it, and asks again with `from: "mac"`. The box then pulls the three
/// files (`SHA256SUMS`, its `.sig`, the asset) piece by piece with `host.update.get`, each
/// answered by a `host.update.piece`, and updates from them with the same checks.
package enum UpdateWire {
    package static let cap = "update"
    package static let keep = "host.keep"
    package static let update = "host.update"
    package static let result = "host.update.result"
    package static let get = "host.update.get"
    package static let piece = "host.update.piece"
    /// `Update.from` when the Mac holds the files.
    package static let fromMac = "mac"
    /// The most bytes one piece carries (before base64): well under a box's inbound frame cap.
    package static let pieceSize = 128 * 1024

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

    /// Mac → box: update to `version` (the latest release the Mac knows) or newer. `from` is
    /// `mac` when the box should pull the files from the Mac instead of GitHub.
    package struct Update: Codable, Equatable, Sendable {
        package var t = UpdateWire.update
        package var id: String
        package var version: String
        package var by: String
        package var from: String?

        package init(id: String, version: String, by: String, from: String? = nil) {
            self.id = id
            self.version = version
            self.by = by
            self.from = from
        }
    }

    /// Box → Mac: the piece of `name` from `offset`, for the update `id`.
    package struct Get: Codable, Equatable, Sendable {
        package var t = UpdateWire.get
        package var id: String
        package var name: String
        package var offset: Int

        package init(id: String, name: String, offset: Int) {
            self.id = id
            self.name = name
            self.offset = offset
        }
    }

    /// Mac → box: at most `pieceSize` bytes of `name` from `offset`, base64, of `total`. A `total`
    /// of 0 says the Mac has no such file for that update.
    package struct Piece: Codable, Equatable, Sendable {
        package var t = UpdateWire.piece
        package var id: String
        package var name: String
        package var offset: Int
        package var total: Int
        package var data: String

        package init(id: String, name: String, offset: Int, total: Int, data: String) {
            self.id = id
            self.name = name
            self.offset = offset
            self.total = total
            self.data = data
        }
    }

    /// Box → Mac: why it didn't update. `started` is sent once the update runs; the restart
    /// follows. `offline`: GitHub can't be reached from the box; `asset` names the file it runs.
    package struct Result: Codable, Equatable, Sendable {
        package enum Outcome: String, LenientEnum { case started, busy, current, failed, offline, unknown }
        package var t = UpdateWire.result
        package var id: String
        package var outcome: Outcome
        /// The box's own words, one line.
        package var line: String
        package var asset: String?

        package init(id: String, outcome: Outcome, line: String, asset: String? = nil) {
            self.id = id
            self.outcome = outcome
            self.line = line
            self.asset = asset
        }
    }
}
