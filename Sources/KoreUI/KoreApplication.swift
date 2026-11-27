import AppKit

/// Kore's `NSApp`. AppKit catches an Objective-C exception that reaches its event loop, reports
/// it and goes on. One that unwound out of a Swift job (a main-actor task's body; the concurrency
/// runtime has no cleanups for it) leaves the runtime's record of that job behind, pointing into
/// a stack that's gone: the next main-actor check reads it and crashes somewhere unrelated, a
/// moment later (`kore-storylines`, 2026-11-24, in `Waits`' run-loop observer). Such an exception
/// ends Kore here instead, its name, reason and throw site in the crash report; any other goes on
/// as AppKit has it.
package final class KoreApplication: NSApplication {
    /// Made the app before SwiftUI starts it (it takes the one there is).
    package static func install() { _ = KoreApplication.shared }

    /// Each exception AppKit caught and goes on from, before it's logged: the storylines fail
    /// the one running with it.
    package static var reported: (@MainActor (NSException) -> Void)?

    nonisolated package override func reportException(_ exception: NSException) {
        if Self.leftAJob() {
            let thrown = exception.callStackSymbols.joined(separator: "\n")
            fatalError("Objective-C exception out of a Swift job: \(exception.name.rawValue): \(exception.reason ?? "")\n\(thrown)")
        }
        nonisolated(unsafe) let exception = exception
        MainActor.assumeIsolated {
            Self.reported?(exception)
            super.reportException(exception)
        }
    }

    /// The runtime names a task as running on this thread, yet no job runs on its stack: the job
    /// was unwound, and the runtime's record of it dangles.
    nonisolated static func leftAJob() -> Bool {
        guard withUnsafeCurrentTask(body: { $0 != nil }) else { return false }
        return !Thread.callStackReturnAddresses.contains { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address.uintValue), &info) != 0, let path = info.dli_fname else { return false }
            return String(cString: path).hasSuffix("/libswift_Concurrency.dylib")
        }
    }
}
