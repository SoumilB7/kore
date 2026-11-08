import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if os(Linux)
/// The static Linux build's allocator (mimalloc): frees what it holds back to the system.
@_silgen_name("mi_collect")
private func mi_collect(_ force: Bool)
#endif

/// Hands memory back once work stops (a CLI's end, an account call, a client gone), so the idle
/// box costs what a fresh one does. On Linux: the allocator's free pages, then this binary's own
/// pages that are clean (they come back from the file when used). Nothing on macOS.
@MainActor
package enum HostMemory {
    private static var due = false

    /// Once, after what's running now has let go of its memory.
    package static func releaseSoon() {
        #if os(Linux)
        guard !due else { return }
        due = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                due = false
                release()
            }
        }
        #endif
    }

    package static func release() {
        #if os(Linux)
        mi_collect(true)
        guard let maps = try? String(contentsOfFile: "/proc/self/maps", encoding: .utf8),
            let me = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        else { return }
        for line in maps.split(separator: "\n") where line.hasSuffix(me) {
            let range = line.split(separator: " ")[0].split(separator: "-")
            guard range.count == 2, let start = UInt(range[0], radix: 16), let end = UInt(range[1], radix: 16),
                let address = UnsafeMutableRawPointer(bitPattern: start)
            else { continue }
            // MADV_PAGEOUT (Linux 5.4): reclaim these pages now; clean file pages just drop.
            _ = madvise(address, Int(end - start), 21)
        }
        #endif
    }
}
