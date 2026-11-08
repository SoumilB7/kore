import Darwin
import Foundation
import QuartzCore

/// The main thread's stack while it's held past `after`, taken once from a background thread:
/// the frames of what held it, for the `stall` line written when it lets go. Nothing runs while
/// the main thread turns: the run loop's observer stamps each step (`step`/`idle`, a lock and a
/// store), and a timer on its own queue looks at the stamp once a second. Only a step older
/// than `after` is sampled: the main thread is suspended for the frame-pointer walk (into a
/// buffer made beforehand: no allocation, no lock while it's stopped), then resumed, and the
/// addresses become image, offset and symbol names. Symbols and offsets only, never contents.
final class StallStacks: @unchecked Sendable {
    static let shared = StallStacks()

    let after: Double
    private let period: Double
    /// Stacks taken per minute at most.
    private let perMinute: Int
    private var lock = os_unfair_lock()
    private var thread: thread_act_t = 0
    /// The current step's start; 0 while the run loop waits.
    private var stepAt: Double = 0
    private var step: UInt64 = 0
    private var sampledStep: UInt64 = 0
    private var taken: [Double] = []
    private var pending: [String]?
    /// Stacks taken since `start`: none while nothing stalls.
    private(set) var samples = 0
    private var timer: DispatchSourceTimer?
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: StallStacks.depth)
    private static let depth = 64

    init(after: Double = 2.0, period: Double = 1.0, perMinute: Int = 3) {
        self.after = after
        self.period = period
        self.perMinute = perMinute
    }

    /// On the main thread: the thread it samples is the one that calls this.
    func start() {
        guard timer == nil else { return }
        thread = mach_thread_self()
        // Its own queue at the main thread's own priority: under load a utility queue is the
        // first to starve, and a stall under load is the one to catch.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kore.stall-stacks", qos: .userInteractive))
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(Int(period * 500)))
        timer.setEventHandler { [weak self] in self?.look() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if thread != 0 { mach_port_deallocate(mach_task_self_, thread) }
        thread = 0
    }

    /// The run loop started a step (`now`: its clock).
    func step(_ now: Double) {
        os_unfair_lock_lock(&lock)
        stepAt = now
        step &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// The run loop is about to wait: nothing is held.
    func idle() {
        os_unfair_lock_lock(&lock)
        stepAt = 0
        os_unfair_lock_unlock(&lock)
    }

    /// The stack taken while the main thread was last held, once: nil when none was.
    func take() -> [String]? {
        os_unfair_lock_lock(&lock)
        defer { pending = nil; os_unfair_lock_unlock(&lock) }
        return pending
    }

    private func look() {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        taken.removeAll { now - $0 > 60 }
        guard thread != 0, stepAt > 0, now - stepAt > after, sampledStep != step, taken.count < perMinute else {
            os_unfair_lock_unlock(&lock)
            return
        }
        sampledStep = step
        taken.append(now)
        let held = step
        os_unfair_lock_unlock(&lock)
        let count = walk()
        guard count > 0 else { return }
        let frames = Self.frames(UnsafeBufferPointer(start: buffer, count: count))
        os_unfair_lock_lock(&lock)
        samples += 1
        if step == held { pending = frames }
        os_unfair_lock_unlock(&lock)
    }

    /// The main thread's return addresses, newest first, into `buffer`: it's stopped for the
    /// walk only, and nothing in between allocates or locks.
    private func walk() -> Int {
        #if arch(arm64)
        // Everything the walk touches is read before the main thread stops: while it's stopped only
        // mach calls and plain stores run (no allocation, lock, logging, or runtime lookup).
        let thread = self.thread
        let buffer = self.buffer
        let depth = Self.depth
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        var pair: (UInt, UInt) = (0, 0)
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &size) }
        }
        guard got == KERN_SUCCESS else { return 0 }
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var n = 0
        buffer[n] = UInt(state.__pc) & mask
        n += 1
        buffer[n] = UInt(state.__lr) & mask
        n += 1
        var fp = UInt(state.__fp)
        // A corrupt chain can't loop: the depth is capped and each frame must sit above the last.
        while n < depth, fp != 0, fp & 7 == 0 {
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(16), vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard ok == KERN_SUCCESS, read == 16, pair.1 != 0 else { break }
            buffer[n] = pair.1 & mask
            n += 1
            guard pair.0 > fp else { break }
            fp = pair.0
        }
        return n
        #else
        return 0
        #endif
    }

    /// Kore's own frames (any image outside the system's), up to 12, as `symbol image+offset`;
    /// the top three of any image when none is Kore's.
    static func frames(_ addresses: UnsafeBufferPointer<UInt>) -> [String] {
        var own: [String] = []
        var any: [String] = []
        for address in addresses {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else { continue }
            let path = String(cString: file)
            let image = (path as NSString).lastPathComponent
            let offset = address - UInt(bitPattern: info.dli_fbase)
            let symbol = info.dli_sname.map { demangle(String(cString: $0)) } ?? "?"
            let frame = "\(symbol) \(image)+0x\(String(offset, radix: 16))"
            if any.count < 3 { any.append(frame) }
            if !path.hasPrefix("/usr/lib/"), !path.hasPrefix("/System/") {
                own.append(frame)
                if own.count == 12 { break }
            }
        }
        return own.isEmpty ? any : own
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    private static let swiftDemangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    /// A Swift symbol's readable name, shortened to the function's own (no module, no types).
    static func demangle(_ mangled: String) -> String {
        guard let swiftDemangle, let out = mangled.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else { return mangled }
        defer { free(out) }
        var name = String(cString: out)
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        return String(name.suffix(60))
    }
}
