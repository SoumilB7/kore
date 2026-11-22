import Foundation
import KoreCore

/// One plan reading each time a login goes quiet: after its chats' last turn ends and nothing
/// of that login has run for `settle`. A turn's own reading (`rate_limit_event`, Codex's pushed
/// limits) comes as each request begins, before it's spent, so without this the plan's next
/// reading would come with the next turn, and a rise from elsewhere meanwhile would share an
/// interval with Kore's last request (`UsageAttribution.split`). The read is the chat's own
/// CLI's (Claude's `get_usage`, Codex's `account/rateLimits/read`): no model request, nothing
/// spent. While a login keeps working nothing is read; a read is never needed between two of
/// its requests.
@MainActor
package final class PlanQuietReads {
    package static let shared = PlanQuietReads()

    /// How long a login stays quiet before it's read.
    package static let settle: Duration = .seconds(8)

    /// Waits; tests answer at once.
    package var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Whether a CLI's logins may be read now: never while one of them moves to or from another
    /// device (no CLI touches a login while two copies exist).
    package var allowed: @MainActor (String) -> Bool = { cli in !CLIProfiles.moving.value.contains { $0.hasPrefix(cli + "/") } }

    private var pending: [String: Task<Void, Never>] = [:]

    package init() {}

    /// A login's key: its CLI and account (unknown: the CLI alone).
    package static func key(_ cli: String, _ account: String?) -> String { cli + "/" + (account ?? "?") }

    /// A request of this login began: it isn't quiet; no read waits.
    package func busy(_ cli: String, account: String?) {
        pending.removeValue(forKey: Self.key(cli, account))?.cancel()
    }

    /// A turn of this login ended: once it has been quiet for `settle`, `read` runs (the last
    /// turn to end reads; each end before it waits again).
    package func ended(_ cli: String, account: String?, read: @escaping @MainActor () async -> Void) {
        let key = Self.key(cli, account)
        pending[key]?.cancel()
        let sleep = sleep
        pending[key] = Task { [weak self] in
            do { try await sleep(Self.settle) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pending[key] = nil
            guard self.allowed(cli) else { return }
            await read()
        }
    }

    /// Whether a read waits for `cli`'s `account` (tests).
    package func waiting(_ cli: String, account: String?) -> Bool { pending[Self.key(cli, account)] != nil }
}
