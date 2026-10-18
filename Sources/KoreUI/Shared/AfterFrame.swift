import Foundation

/// Runs `action` once the frame being built now has been committed: the next time the main run
/// loop is about to wait (after Core Animation's commit), it queues `action` for the pass after.
/// For work a view can show a frame later, so that frame has less to build.
@MainActor func afterThisFrame(_ action: @escaping @MainActor () -> Void) {
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated(action) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}
