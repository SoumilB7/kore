import Foundation
import HostClient
import LinkProtocol
import Testing

/// New box…'s last step on the Mac (0.3.9): a box claimed from here has its Kore's tailnet signed
/// in from here. Its page opens once, its row says so until the box says it's signed in, then
/// "Ready" for a moment. Timers are the test's own: nothing waits.
@MainActor
@Suite("box own follow")
struct BoxOwnFollowTests {
    @MainActor final class Timers {
        var due: [(TimeInterval, @MainActor () -> Void)] = []
        func fire(_ seconds: TimeInterval) {
            let now = due.filter { $0.0 == seconds }
            due.removeAll { $0.0 == seconds }
            for timer in now { timer.1() }
        }
    }

    func follow(_ timers: Timers) -> BoxOwnFollow {
        let follow = BoxOwnFollow()
        follow.schedule = { seconds, work in
            timers.due.append((seconds, work))
            return {}
        }
        return follow
    }

    @Test func aClaimedBoxSignsInFromHere() {
        let timers = Timers()
        let follow = follow(timers)
        var opened: [URL] = []
        let page = "https://login.tailscale.com/a/box"
        follow.follow("dev-1", name: "mybox", own: .signedOut(.never, page: page)) { opened.append($0) }
        #expect(opened == [URL(string: page)!])
        #expect(follow.line("dev-1") == "Kore's tailnet on mybox · finish signing in, it's open in your browser")
        // The box says it again (a new page, the same sign-in): never a second tab.
        follow.heard(["mybox", "dev-1"], own: .signedOut(.never, page: page + "2"))
        #expect(opened.count == 1)
        follow.heard(["dev-1"], own: .signedIn("me@example.com"))
        #expect(follow.line("dev-1") == "Ready · Kore's tailnet: signed in as me@example.com")
        timers.fire(BoxOwnFollow.shownFor)
        #expect(follow.line("dev-1") == nil)
        // Not followed any more: nothing opens.
        follow.heard(["dev-1"], own: .signedOut(.loggedOut, page: page))
        #expect(opened.count == 1 && follow.line("dev-1") == nil)
    }

    @Test func aBoxThatSaysNothingShowsNothingAndEnds() {
        let timers = Timers()
        let follow = follow(timers)
        var opened = 0
        follow.follow("dev-2", name: "gpubox", own: nil) { _ in opened += 1 }
        #expect(follow.line("dev-2") == nil && opened == 0)
        // Its page comes later, on its link.
        follow.heard(["gpubox"], own: nil)
        follow.heard(["dev-2"], own: .signedOut(.never))
        #expect(follow.line("dev-2") == "Kore's tailnet on gpubox…" && opened == 0)
        timers.fire(BoxOwnFollow.wait)
        #expect(follow.line("dev-2") == nil)
    }

    /// The row shows the step first.
    @Test func theRowSaysTheStep() {
        var row = DeviceRow(id: "dev-1", kind: .box, name: "mybox", status: .connected)
        row.ownStep = "Kore's tailnet on mybox · finish signing in, it's open in your browser"
        row.own = .signedOut(.never, page: "https://login.tailscale.com/a/box")
        #expect(DevicesWords.detail(row, now: Date()) == row.ownStep)
    }
}
