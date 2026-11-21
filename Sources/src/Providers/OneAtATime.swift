import Foundation

/// Work a backend does one at a time, in the order it was asked: each waits for the one before
/// it to end (done or failed). A rollback's cut point and the history it adopts are one step: two
/// interleaved at their awaits would leave the CLI cut at one message and the history at another.
@MainActor
package final class OneAtATime {
    private var last: Task<Void, Never>?

    package init() {}

    package func run<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let before = last
        let task = Task { @MainActor in
            await before?.value
            return try await work()
        }
        last = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }
}
