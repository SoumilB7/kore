import AppKit
import Testing

@testable import KoreUI

@MainActor
@Suite("story registry", .serialized)
struct StoryRegistryTests {
    private let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Ordered in, off every screen: only a shown window's elements answer.
        window.orderFront(nil)
        return window
    }()

    private func view(_ frame: CGRect) -> NSView {
        let view = NSView(frame: frame)
        window.contentView?.addSubview(view)
        return view
    }

    @Test func theLatestLiveRegistrationAnswers() {
        let row = view(CGRect(x: 0, y: 0, width: 100, height: 20))
        let button = view(CGRect(x: 80, y: 0, width: 20, height: 20))
        var pressed = ""
        let a = StoryRegistry.register("t.answer[A].fork", in: row, press: { pressed = "row" })
        let b = StoryRegistry.register("t.answer[A].fork", in: button, press: { pressed = "button" })
        StoryRegistry.entry("t.answer[A].fork")?.press?()
        #expect(pressed == "button")
        StoryRegistry.unregister(b)
        StoryRegistry.entry("t.answer[A].fork")?.press?()
        #expect(pressed == "row")
        StoryRegistry.unregister(a)
        #expect(StoryRegistry.entry("t.answer[A].fork") == nil)
    }

    @Test func anEntryOutsideAWindowDoesNotAnswer() {
        let loose = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let token = StoryRegistry.register("t.loose", in: loose)
        #expect(StoryRegistry.entry("t.loose") == nil)
        #expect(!StoryRegistry.ids.contains("t.loose"))
        StoryRegistry.unregister(token)
    }

    @Test func aClosedWindowsEntryDoesNotAnswer() {
        let closed = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        closed.isReleasedWhenClosed = false
        closed.orderFront(nil)
        let stale = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        closed.contentView?.addSubview(stale)
        let old = StoryRegistry.register("t.agents", in: stale)
        closed.close()
        #expect(StoryRegistry.entry("t.agents") == nil)
        let live = StoryRegistry.register("t.agents", in: view(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(StoryRegistry.entry("t.agents")?.token == live)
        StoryRegistry.unregister(old)
        StoryRegistry.unregister(live)
    }

    @Test func framesAreInWindowCoordinatesAndPartsUseTheirRect() {
        let gutter = view(CGRect(x: 10, y: 50, width: 30, height: 200))
        let whole = StoryRegistry.register("t.gutter", in: gutter)
        let part = StoryRegistry.register("t.gutter.fold[3]", in: gutter, rect: { CGRect(x: 0, y: 60, width: 30, height: 20) })
        #expect(StoryRegistry.entry("t.gutter")?.frame == CGRect(x: 10, y: 50, width: 30, height: 200))
        #expect(StoryRegistry.entry("t.gutter.fold[3]")?.frame == CGRect(x: 10, y: 110, width: 30, height: 20))
        StoryRegistry.unregister(whole)
        StoryRegistry.unregister(part)
    }

    @Test func nearestSharesTheLongestPrefix() {
        let row = view(CGRect(x: 0, y: 0, width: 10, height: 10))
        let tokens = ["t.answer[A]", "t.answer[A].copy", "t.answer[B]", "t.user[C]"].map { StoryRegistry.register($0, in: row) }
        #expect(StoryRegistry.nearest(to: "t.answer[A].fork") == ["t.answer[A]", "t.answer[A].copy"])
        #expect(StoryRegistry.nearest(to: "zzz").isEmpty)
        tokens.forEach(StoryRegistry.unregister)
    }
}
