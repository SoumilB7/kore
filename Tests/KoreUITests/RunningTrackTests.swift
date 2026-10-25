import AppKit
import SwiftUI
import Testing

@testable import KoreUI

@MainActor
@Suite("Running track: native geometry, motion and lifetime")
struct RunningTrackTests {
    private func geometry(_ count: Int) -> RunningTrackGeometry {
        RunningTrackGeometry(size: CGSize(width: RunningTrack.width(count), height: Size.agentTrack + Stroke.emphasis))
    }

    private func near(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) < 0.000_001)
    }

    @Test func capsuleAndFixedArcLength() {
        for count in 1...3 {
            let geometry = geometry(count)
            let box = geometry.path.boundingBoxOfPath
            near(box.minX, Stroke.emphasis / 2)
            near(box.minY, Stroke.emphasis / 2)
            near(box.width, RunningTrack.width(count) - Stroke.emphasis)
            near(box.height, Size.agentTrack)
            near(geometry.perimeter, .pi * Size.agentTrack + 2 * CGFloat(count - 1) * Size.agentTrackStep)
            #expect(RunningTrackGeometry.dashLength < geometry.perimeter)
        }
        near(RunningTrack.width(0), RunningTrack.width(1))
        near(RunningTrack.width(20), RunningTrack.width(3))
        #expect(RunningTrackGeometry(size: .zero).path.isEmpty)
        #expect(RunningTrackGeometry(size: .zero).perimeter == 0)
    }

    @Test func speedAndFractionSurviveResizeAndPause() {
        var phase = RunningTrackPhase()
        let one = geometry(1).perimeter
        let three = geometry(3).perimeter
        phase.update(perimeter: one, running: true, at: 10)
        let quarter = 10 + Motion.ringLap / 4
        near(phase.value(at: quarter), 0.25)
        phase.update(perimeter: three, running: true, at: quarter)
        near(phase.value(at: quarter), 0.25)
        let half = quarter + Double(three / RunningTrackPhase.speed) / 4
        near(phase.value(at: half), 0.5)
        phase.update(perimeter: three, running: false, at: half)
        near(phase.value(at: half + 1_000), 0.5)
        phase.update(perimeter: one, running: true, at: half + 1_000)
        near(phase.value(at: half + 1_000), 0.5)
        near(phase.value(at: half + 1_000 + Motion.ringLap / 4), 0.75)
    }

    @Test func nativeDashUsesConstantSpeedAndOneAnimation() throws {
        let clock = Clock()
        let (window, host) = mounted(clock)
        defer { window.close() }
        host.configure(indexes: [0], background: false, still: false)
        host.setWindowVisible(true)
        let first = try #require(host.dash.animation(forKey: RunningTrackHost.motionKey) as? CABasicAnimation)
        #expect(first.keyPath == "lineDashPhase")
        #expect(first.repeatCount == .infinity)
        near(first.duration, Motion.ringLap)
        let from = try #require(first.fromValue as? NSNumber)
        let to = try #require(first.toValue as? NSNumber)
        near(from.doubleValue - to.doubleValue, geometry(1).perimeter)
        // An unchanged SwiftUI update neither restarts nor accumulates native animations.
        host.configure(indexes: [0], background: false, still: false)
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
        let unchanged = try #require(host.dash.animation(forKey: RunningTrackHost.motionKey))
        near(unchanged.beginTime, first.beginTime)
        clock.time += Motion.ringLap / 4
        host.configure(indexes: [0, 1, 2], background: true, still: false)
        host.setFrameSize(geometry(3).size)
        host.layoutSubtreeIfNeeded()
        near(host.phase.fraction, 0.25)
        let resized = try #require(host.dash.animation(forKey: RunningTrackHost.motionKey) as? CABasicAnimation)
        near(resized.duration, Double(geometry(3).perimeter / RunningTrackPhase.speed))
        near((resized.fromValue as? NSNumber)?.doubleValue ?? -1, 0.75 * geometry(3).perimeter)
        #expect(host.track.lineDashPattern == Stroke.backgroundDash.map { NSNumber(value: Double($0)) })
        let dashPattern = try #require(host.dash.lineDashPattern)
        near(dashPattern[0].doubleValue, RunningTrackGeometry.dashLength)
        near(dashPattern.reduce(0) { $0 + $1.doubleValue }, geometry(3).perimeter)
    }

    @Test func countTransitionKeepsLeavingShapesAndFadesAtTheirSlot() {
        let (window, host) = mounted(Clock())
        defer { window.close() }
        host.configure(indexes: [0], background: false, still: true)
        host.configure(indexes: [0, 1, 3], background: false, still: true)
        #expect(host.marks.map(\.opacity) == [1, 0, 0])
        // A finite SwiftUI width transition supplies intermediate bounds; steady motion does not.
        host.setFrameSize(CGSize(width: RunningTrack.width(3) - Size.agentTrackStep / 2, height: geometry(3).size.height))
        host.layoutSubtreeIfNeeded()
        #expect(host.marks.map(\.opacity) == [1, 1, 0.5])
        let leavingPath = host.marks[2].path
        host.configure(indexes: [0], background: false, still: true)
        #expect(host.marks[2].path == leavingPath)
        #expect(host.marks[2].opacity == 0.5)
        host.setFrameSize(geometry(1).size)
        host.layoutSubtreeIfNeeded()
        #expect(host.marks.map(\.opacity) == [1, 0, 0])
        #expect(host.dash.animationKeys() == nil)
    }

    @Test func hiddenReduceMotionOcclusionAndDetachFreezeAndResume() throws {
        let clock = Clock()
        let (window, host) = mounted(clock)
        defer { window.close() }
        host.configure(indexes: [0, 1], background: false, still: false)
        host.setFrameSize(geometry(2).size)
        host.layoutSubtreeIfNeeded()
        host.setWindowVisible(true)
        clock.time += 0.2
        // `still` is the common native input for hidden tabs and Reduce Motion.
        host.configure(indexes: [0, 1], background: false, still: true)
        let held = host.phase.fraction
        #expect(held > 0)
        #expect(host.dash.animationKeys() == nil)
        clock.time += 100
        host.configure(indexes: [0, 1], background: false, still: false)
        near(host.phase.fraction, held)
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
        clock.time += 0.2
        // The real observer reads a never-ordered window as occluded.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!host.windowVisible)
        #expect(host.dash.animationKeys() == nil)
        let occluded = host.phase.fraction
        clock.time += 100
        host.setWindowVisible(true)
        near(host.phase.fraction, occluded)
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
        window.contentView = NSView()
        #expect(host.window == nil)
        #expect(host.dash.animationKeys() == nil)
        #expect(host.track.superlayer?.superlayer == nil)
        let detached = host.phase.fraction
        clock.time += 100
        window.contentView = host
        host.setWindowVisible(true)
        near(host.phase.fraction, detached)
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
        near(host.dash.contentsScale, window.backingScaleFactor)
    }

    @Test func nativeAncestorHidingPausesWithoutLosingPhase() {
        let clock = Clock()
        let (window, host) = mounted(clock)
        defer { window.close() }
        let container = NSView(frame: host.frame)
        window.contentView = container
        container.addSubview(host)
        host.configure(indexes: [0], background: false, still: false)
        host.setWindowVisible(true)
        clock.time += 0.2
        container.isHidden = true
        #expect(host.isHiddenOrHasHiddenAncestor)
        #expect(host.dash.animationKeys() == nil)
        let held = host.phase.fraction
        #expect(held > 0)
        clock.time += 100
        container.isHidden = false
        #expect(!host.isHiddenOrHasHiddenAncestor)
        near(host.phase.fraction, held)
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
        host.isHidden = true
        #expect(host.dash.animationKeys() == nil)
        host.isHidden = false
        #expect(host.dash.animationKeys() == [RunningTrackHost.motionKey])
    }

    @Test func decorativeHitTestingAndWindowDoNotRetainHost() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        weak var released: RunningTrackHost?
        autoreleasepool {
            let host = RunningTrackHost()
            released = host
            window.contentView = host
            host.configure(indexes: [0], background: false, still: false)
            host.setWindowVisible(true)
            #expect(host.hitTest(.zero) == nil)
            #expect(!host.isAccessibilityElement())
            #expect(host.accessibilityChildren()?.isEmpty != false)
            window.contentView = NSView()
        }
        #expect(released == nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.close()
    }

    private final class Clock {
        var time: CFTimeInterval = 10
    }

    private func mounted(_ clock: Clock) -> (NSWindow, RunningTrackHost) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: RunningTrack.width(1), height: geometry(1).size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = RunningTrackHost(now: { clock.time })
        window.contentView = host
        host.setFrameSize(geometry(1).size)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
}
