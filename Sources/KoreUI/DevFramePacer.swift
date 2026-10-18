import AppKit
import QuartzCore

/// The navigation bench's frame clock (phase 11 research-harness.md §2): a display link in the
/// common run-loop modes (so it ticks through tracking and live resize), a preallocated ring of
/// frame times for hitch counts, and the settle detector the latencies are measured to.
@MainActor
final class DevFramePacer: NSObject {
    /// What "settled" looks at each frame: the transcript's height and offset, and whether the
    /// step's target is on screen with nothing pending.
    struct Probe: Equatable {
        var height: CGFloat
        var offset: CGFloat
        var ready: Bool
    }

    struct Hitches {
        var frames = 0
        var missed = 0
        var over33 = 0
        var worstMS = 0.0
        var hitchMSPerS = 0.0
        var stalls = 0
        var durationS = 0.0
    }

    private var link: CADisplayLink?
    private(set) var frameDuration: CFTimeInterval = 1.0 / 60
    private var probe: () -> Probe? = { nil }

    // Ring of frame timestamps for the current recording.
    private var times = [CFTimeInterval](repeating: 0, count: 8192)
    private var count = 0
    private var recording = false

    // Settling.
    private var last: Probe?
    private var stableSince: CFTimeInterval?
    private var stableFrames = 0
    private var waiter: (since: CFTimeInterval, continuation: CheckedContinuation<CFTimeInterval?, Never>, deadline: CFTimeInterval)?
    // Late jumps: changes after settling with no input.
    private var watchUntil: CFTimeInterval = 0
    private var watched: Probe?
    private(set) var lateJumps = 0

    func start(on view: NSView, probe: @escaping () -> Probe?) {
        self.probe = probe
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func setProbe(_ probe: @escaping () -> Probe?) {
        self.probe = probe
        last = nil
        stableFrames = 0
        stableSince = nil
    }

    // MARK: Recording hitches

    func beginRecording() {
        count = 0
        recording = true
    }

    func endRecording() -> Hitches {
        recording = false
        var result = Hitches()
        guard count > 1 else { return result }
        let period = frameDuration
        var hitch = 0.0
        for i in 1..<count {
            let delta = times[i] - times[i - 1]
            result.missed += max(0, Int((delta / period).rounded()) - 1)
            if delta > 0.0333 { result.over33 += 1 }
            if delta >= 0.033 { result.stalls += 1 }
            result.worstMS = max(result.worstMS, delta * 1000)
            hitch += max(0, delta - period)
        }
        result.frames = count
        result.durationS = times[count - 1] - times[0]
        result.hitchMSPerS = result.durationS > 0 ? hitch * 1000 / result.durationS : 0
        return result
    }

    // MARK: Settling

    /// Waits until the probe reads ready and its height and offset hold still for 3 frames.
    /// Returns the time of the first frame of that still run, or nil on timeout.
    func waitSettled(timeout: CFTimeInterval = 10) async -> CFTimeInterval? {
        let now = CACurrentMediaTime()
        last = nil
        stableFrames = 0
        stableSince = nil
        // The deadline holds without frames too: a covered window or another Space gets none.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, let pending = waiter, pending.since == now else { return }
            waiter = nil
            pending.continuation.resume(returning: nil)
        }
        return await withCheckedContinuation { continuation in
            waiter = (now, continuation, now + timeout)
        }
    }

    /// Counts jumps over 0.5 pt in the next `seconds`, with no input meant to cause them.
    func watchLateJumps(for seconds: CFTimeInterval) {
        lateJumps = 0
        watched = probe()
        watchUntil = CACurrentMediaTime() + seconds
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameDuration = link.duration > 0 ? link.duration : frameDuration
        if recording, count < times.count {
            times[count] = now
            count += 1
        }
        let current = probe()
        if now < watchUntil, let watched, let current {
            if abs(current.height - watched.height) > 0.5 || abs(current.offset - watched.offset) > 0.5 {
                lateJumps += 1
                self.watched = current
            }
        }
        guard let pending = waiter else { return }
        if now > pending.deadline {
            waiter = nil
            pending.continuation.resume(returning: nil)
            return
        }
        guard let current, current.ready else {
            last = nil
            stableFrames = 0
            return
        }
        if let last, abs(last.height - current.height) <= 0.5, abs(last.offset - current.offset) <= 0.5 {
            stableFrames += 1
        } else {
            stableFrames = 1
            stableSince = now
        }
        last = current
        if stableFrames >= 3, let since = stableSince {
            waiter = nil
            pending.continuation.resume(returning: since)
        }
    }
}
