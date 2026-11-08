import Foundation
import KoreCore

/// After a Kore turn ends, the usage index reads what the turn wrote, a few seconds later and
/// once for a run of turns, at low priority: the next Usage popup then has little left to read.
@MainActor
package enum KoreUsageRefresh {
    private static var pending: [String: Task<Void, Never>] = [:]
    /// How long after the last turn ends.
    package static let delay: Duration = .seconds(5)

    package static func soon(_ cli: String) {
        // A box keeps none of the Mac's bookkeeping: no index to read for.
        guard !KoreLog.keepsNothing else { return }
        pending[cli]?.cancel()
        pending[cli] = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await KoreUsage.shared.refresh(cli: cli)
        }
    }
}
