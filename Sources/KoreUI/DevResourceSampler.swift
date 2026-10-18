import Darwin
import Foundation

/// The navigation bench's memory and CPU sampler (phase 11 research-harness.md, addendum): Kore's
/// physical footprint and CPU, and its CLI children's, at 10 Hz on a utility queue, so it keeps
/// sampling through a main-thread stall. Only runs under KORE_BENCH.
final class DevResourceSampler: @unchecked Sendable {
    struct Sample {
        let time: Double
        let footprint: UInt64
        let cpu: Double
        let cliFootprint: UInt64
        let cliCPU: Double
    }

    /// One step's numbers.
    struct Step {
        var memStartMB = 0.0
        var memPeakMB = 0.0
        var peakExact = false
        var memSettledMB = 0.0
        var cpuS = 0.0
        var cpuPeakPct = 0.0
        var cpuAvgPct = 0.0
        var cliCPUS = 0.0
        var cliCPUPeakPct = 0.0
        var cliMemPeakMB = 0.0
        var cliMemSettledMB = 0.0
        var samples = 0
        var samplerCPUS = 0.0
    }

    private let queue = DispatchQueue(label: "dev.kore.bench.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var stepStart = 0
    private var ledgerAtStart: UInt64 = 0
    private var startCPU = 0.0
    private var startCLICPU = 0.0
    private var samplerCPU = 0.0
    private let lock = NSLock()
    let hz: Double

    init(hz: Double = Double(ProcessInfo.processInfo.environment["KORE_BENCH_SAMPLE_HZ"] ?? "") ?? 10) {
        self.hz = hz
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let before = Self.threadCPU()
        let sample = Self.sample()
        lock.lock()
        samples.append(sample)
        samplerCPU += Self.threadCPU() - before
        lock.unlock()
    }

    /// Marks the start of a step.
    func begin() {
        let now = Self.sample()
        lock.lock()
        samples.append(now)
        stepStart = samples.count - 1
        ledgerAtStart = Self.vmInfo().peak
        startCPU = now.cpu
        startCLICPU = now.cliCPU
        samplerCPU = 0
        lock.unlock()
    }

    /// The step's numbers, from its start to now. `settledFrom` is when it settled: the settled
    /// footprint is the mean of the samples from 1 s after that (or the last 5).
    func end(settledFrom settled: Double?) -> Step {
        let now = Self.sample()
        let peakNow = Self.vmInfo().peak
        lock.lock()
        samples.append(now)
        let window = Array(samples[stepStart...])
        let sampler = samplerCPU
        let ledgerStart = ledgerAtStart
        lock.unlock()

        var step = Step()
        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        step.memStartMB = mb(window.first?.footprint ?? 0)
        let sampledPeak = window.map(\.footprint).max() ?? 0
        // The kernel's lifetime peak is exact when it rose during the step.
        if peakNow > ledgerStart {
            step.memPeakMB = mb(peakNow)
            step.peakExact = true
        } else {
            step.memPeakMB = mb(sampledPeak)
        }
        let late = settled.map { from in window.filter { $0.time >= from + 1 } } ?? []
        let tail = late.isEmpty ? Array(window.suffix(5)) : late
        step.memSettledMB = mb(tail.map(\.footprint).reduce(0, +) / UInt64(max(tail.count, 1)))
        step.cpuS = now.cpu - (window.first?.cpu ?? now.cpu)
        step.cliCPUS = now.cliCPU - (window.first?.cliCPU ?? now.cliCPU)
        var peak = 0.0
        var cliPeak = 0.0
        for (a, b) in zip(window, window.dropFirst()) where b.time > a.time {
            peak = max(peak, (b.cpu - a.cpu) / (b.time - a.time) * 100)
            cliPeak = max(cliPeak, (b.cliCPU - a.cliCPU) / (b.time - a.time) * 100)
        }
        step.cpuPeakPct = peak
        step.cliCPUPeakPct = cliPeak
        let duration = (window.last?.time ?? 0) - (window.first?.time ?? 0)
        step.cpuAvgPct = duration > 0 ? step.cpuS / duration * 100 : 0
        step.cliMemPeakMB = mb(window.map(\.cliFootprint).max() ?? 0)
        step.cliMemSettledMB = mb(tail.map(\.cliFootprint).reduce(0, +) / UInt64(max(tail.count, 1)))
        step.samples = window.count
        step.samplerCPUS = sampler
        return step
    }

    /// The raw series since a step began (KORE_BENCH_TRACE=1).
    func trace() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples[stepStart...])
    }

    // MARK: - Reading the kernel

    static func sample() -> Sample {
        let (cliMemory, cliCPU) = cliTree()
        return Sample(
            time: ProcessInfo.processInfo.systemUptime, footprint: vmInfo().footprint, cpu: cpuSeconds(getpid()),
            cliFootprint: cliMemory, cliCPU: cliCPU)
    }

    /// phys_footprint (what vmmap shows) and the kernel's lifetime peak of it.
    static func vmInfo() -> (footprint: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
    }

    /// Mach ticks to seconds (125/3 ns per tick on this M4).
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }

    static func cpuSeconds(_ pid: pid_t) -> Double {
        guard let info = rusage(pid) else { return 0 }
        return Double(info.ri_user_time + info.ri_system_time) * timebase
    }

    /// The CLI processes under Kore (live ones; RUSAGE_CHILDREN only counts reaped children).
    static func cliTree() -> (footprint: UInt64, cpu: Double) {
        var memory: UInt64 = 0
        var cpu = 0.0
        var pending = children(of: getpid())
        var seen = Set<pid_t>()
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let info = rusage(pid) {
                memory += info.ri_phys_footprint
                cpu += Double(info.ri_user_time + info.ri_system_time) * timebase
            }
            pending += children(of: pid)
        }
        return (memory, cpu)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// This thread's CPU so far, for the sampler's own cost.
    private static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }
}
