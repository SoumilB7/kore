import AppKit
import Testing

@testable import KoreUI

/// An exception out of a Swift job leaves the runtime naming a task with no job on the stack
/// (`KoreApplication`); everywhere else a task's job is right there, or there's no task.
@Suite("Kore's NSApp")
struct KoreApplicationTests {
    @Test func noTaskOrATaskWhoseJobRunsIsLeftAlone() async {
        #expect(!KoreApplication.leftAJob(), "in a test's task: its job runs below")
        #expect(await Task.detached { KoreApplication.leftAJob() }.value == false)
        #expect(await MainActor.run { KoreApplication.leftAJob() } == false)
        let thread = await withCheckedContinuation { done in
            Thread { done.resume(returning: KoreApplication.leftAJob()) }.start()
        }
        #expect(!thread, "no task on a plain thread")
    }
}
