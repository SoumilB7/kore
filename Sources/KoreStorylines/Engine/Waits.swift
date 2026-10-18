import AppKit

/// Condition waits: each is checked again after every pass of the main run loop (after Core
/// Animation's commit, so a layout's results are in) and every 50 ms, for changes the run loop
/// doesn't see (files on disk, a CLI's process). No step sleeps.
@MainActor
final class Waits {
    private struct Waiter {
        let id: UUID
        /// Checks the condition; true once the wait is over (met or failed).
        let attempt: () -> Bool
        let deadline: ContinuousClock.Instant
        let expire: () -> Void
    }

    private var waiters: [Waiter] = []
    private var observer: CFRunLoopObserver?
    private var timer: Timer?
    /// Main run-loop passes so far; `StoryContext.idle` counts them.
    private(set) var passes = 0

    func until<T>(_ label: String, timeout: Duration, _ check: @escaping @MainActor () throws -> T?) async throws -> T {
        if let value = try check() { return value }
        let deadline = ContinuousClock.now + timeout
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            waiters.append(Waiter(
                id: id,
                attempt: {
                    do {
                        guard let value = try check() else { return false }
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return true
                },
                deadline: deadline,
                expire: { continuation.resume(throwing: StoryFailure.timedOut(label)) }))
            start()
        }
    }

    /// Something changed that a wait might be watching (an event arrived).
    func poke() { evaluate() }

    func start() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func evaluate() {
        passes += 1
        guard !waiters.isEmpty else { return }
        let now = ContinuousClock.now
        // Resuming can add waiters (a step's next wait); check the ones that were here.
        for waiter in waiters {
            if waiter.attempt() {
                waiters.removeAll { $0.id == waiter.id }
            } else if now >= waiter.deadline {
                waiters.removeAll { $0.id == waiter.id }
                waiter.expire()
            }
        }
    }
}
