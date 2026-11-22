import AppKit
import HostClient
import KoreUI

/// The Welcome's "+" with a kore-host box on the tailnet (owner recording, 0.3.7: its rows jumped
/// every frame and the popup slid over "This Mac"): it opens under the switcher's bar, mybox, Use
/// SSH… and New box… in it, and over a second of the tailnet saying something its frame and rows
/// stay where they first drew.
final class WelcomeAddStill: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            DevicesSetUp(on: true, release: true, peers: ["mybox"]),
            WelcomeHasHosts(),
            ShowWelcome(),
            Do("Press the Welcome's +") { _ in
                guard let welcome = DevicesFromWelcome.welcome else { throw StoryFailure.other("no Welcome") }
                guard let plus = StoryRegistry.entry(StoryID.Boxes.add.raw, in: welcome)?.press else {
                    throw StoryFailure.elementNotFound(StoryID.Boxes.add.raw, nearby: StoryRegistry.nearest(to: StoryID.Boxes.add.raw))
                }
                plus()
            },
            WelcomeAddRowsStill(),
        ]
    }
}

/// The SSH config names a host, so the Welcome shows its switcher (and with it "+").
private struct WelcomeHasHosts: Step {
    var label: String { "The SSH config names a host" }

    func run(_ story: StoryContext) async throws {
        StorylineSeams.sshHosts = { true }
        _ = story.stash(WelcomeHostsReset.self) { WelcomeHostsReset() }
    }
}

private final class WelcomeHostsReset: StoryFinishing {
    func finish() {
        StorylineSeams.sshHosts = nil
        NetPopupHost.shared.close()
    }
}

/// Once the rows are in: sampled every frame for a second while the tailnet's bus says something
/// every 20 ms, the popup is placed no more, its rows don't move, and it sits under the bar.
private struct WelcomeAddRowsStill: Step {
    var label: String { "The + list's rows stay still for a second of tailnet events" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let ids = [StoryID.Net.welcomePeer("mybox").raw, StoryID.Net.useSSH.raw, StoryID.Net.newBox.raw]
        guard let welcome = DevicesFromWelcome.welcome else { throw StoryFailure.other("no Welcome") }
        func rows() -> [CGRect?] { ids.map { StoryRegistry.entry($0, in: welcome)?.frame } }
        try await story.until("mybox, Use SSH… and New box… listed") { rows().allSatisfy { $0 != nil } }
        try await Task.sleep(for: .milliseconds(100))
        let first = rows()
        let frame = NetPopupHost.shared.frame
        let placed = NetPopupHost.shared.placements
        var moved: [String] = []
        for tick in 0..<60 {
            if tick % 2 == 0 { Devices.shared.changed() }
            try await Task.sleep(for: .milliseconds(16))
            let now = rows()
            if now != first || NetPopupHost.shared.frame != frame { moved.append("tick \(tick): popup \(NetPopupHost.shared.frame.map { "\($0)" } ?? "gone") rows \(now)") }
        }
        if let png = snapshot(welcome) { try png.write(to: story.outputs.appendingPathComponent("welcome-add-still.png")) }
        guard moved.isEmpty, NetPopupHost.shared.placements == placed else {
            throw StoryFailure.expectation("the list moved \(moved.count)× (placed \(NetPopupHost.shared.placements - placed) more), first \(frame.map { "\($0)" } ?? "none") \(first); \(moved.prefix(3))")
        }
        // Under the switcher's bar: its top below "This Mac" (the window's content is flipped).
        guard let frame, let content = welcome.contentView,
              let mac = StoryRegistry.entry(StoryID.Boxes.place("mac").raw, in: welcome)?.frame else { throw StoryFailure.other("no popup or This Mac") }
        let macInContent = content.convert(mac, from: nil)
        let top = content.isFlipped ? frame.minY : frame.maxY
        let under = content.isFlipped ? top >= macInContent.maxY : top <= macInContent.minY
        guard under, !frame.intersects(macInContent) else {
            throw StoryFailure.expectation("the list covers This Mac: popup \(frame), This Mac \(macInContent)")
        }
    }
}
