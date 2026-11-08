import Foundation
import Observation

/// When a box window's link-down card shows, so a flapping link never makes it flash. It shows once
/// the link has been down `showAfter` (a blip shows nothing). Once shown it stays through reconnects
/// that come and go, and closes only once the link has stayed up: `hideAfter` normally, or the
/// connection's own stable rule (`HostConnection.stableAfter`, the one its backoff resets on) after
/// a quick drop in the last minute. A quick drop is a link that died before that rule. After
/// `dropsToSay` quick drops in a minute the card says the box keeps dropping.
///
/// Time comes in from outside (`linked`, `tick`), and `wake` says when it next needs a look:
/// nothing runs while the card is hidden and the link is up.
@MainActor @Observable
final class LinkDownCard {
    typealias Instant = ContinuousClock.Instant

    static let showAfter: Duration = .seconds(2)
    static let hideAfter: Duration = .seconds(5)
    static let dropWindow: Duration = .seconds(60)
    static let dropsToSay = 3

    private(set) var shown = false
    private(set) var keepsDropping = false
    /// When the box last said anything, kept while the card is up (the link coming back for a moment
    /// clears the connection's).
    private(set) var lastHeard: Date?

    /// The connection's stable rule.
    @ObservationIgnored var stableAfter: Duration
    @ObservationIgnored private var down = false
    @ObservationIgnored private var downAt: Instant?
    @ObservationIgnored private var upAt: Instant?
    /// Quick drops, oldest first, as of the last minute.
    @ObservationIgnored private var drops: [Instant] = []

    init(stableAfter: Duration = .seconds(30)) {
        self.stableAfter = stableAfter
    }

    /// The link came up or went at `now`; `heard` is the connection's last word from the box.
    func linked(_ up: Bool, at now: Instant, heard: Date? = nil) {
        if let heard { lastHeard = heard }
        // First seen up: up since now, as far as the card knows.
        if up, !down, upAt == nil { upAt = now }
        guard up == down else { return tick(at: now) }
        if up {
            down = false
            upAt = now
        } else {
            down = true
            downAt = now
            if let upAt, now - upAt < stableAfter { drops.append(now) }
            upAt = nil
        }
        tick(at: now)
    }

    /// What `now` makes of it: shown, closed, or still saying it keeps dropping.
    func tick(at now: Instant) {
        drops.removeAll { now - $0 >= Self.dropWindow }
        let dropping = drops.count >= Self.dropsToSay
        if keepsDropping != dropping { keepsDropping = dropping }
        if down {
            if !shown, let downAt, now - downAt >= Self.showAfter { shown = true }
        } else if shown, let upAt, now - upAt >= hold {
            shown = false
            lastHeard = nil
        }
    }

    /// How long the link stays up before the card closes.
    private var hold: Duration { drops.isEmpty ? Self.hideAfter : max(Self.hideAfter, stableAfter) }

    /// When the card next needs a `tick`: its show while the link is down, its close while it's up,
    /// and a drop leaving the minute while it says so. Nil when nothing will change on its own.
    var wake: Instant? {
        if down { return shown ? dropExpiry : downAt.map { $0 + Self.showAfter } }
        guard shown, let upAt else { return nil }
        let close = upAt + hold
        return dropExpiry.map { min($0, close) } ?? close
    }

    private var dropExpiry: Instant? { keepsDropping ? drops.first.map { $0 + Self.dropWindow } : nil }
}
