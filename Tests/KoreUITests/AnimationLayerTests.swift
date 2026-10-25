import AppKit
import SwiftUI
import Testing

@testable import KoreUI

@MainActor
@Suite("Animation layer lifecycle")
struct AnimationLayerTests {
    private let fade = LayerAnimation(keyPath: "opacity", from: 1, to: 0.35, duration: 0.8,
                                      autoreverses: true, easing: .easeInEaseOut)

    /// No window is ordered in: the test controls only the occlusion value and notifications.
    private func window(visible: Bool) -> VisibilityWindow {
        _ = NSApplication.shared
        let window = VisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.testVisible = visible
        return window
    }

    @Test func unchangedConfigurationKeepsItsPhaseAndChangedInputsReplaceTheKey() throws {
        let content = NSView()
        let host = OwnLayer<Text>.Host(content, fade)
        let layer = try #require(content.layer)
        let installed = try #require(layer.animation(forKey: "own") as? CABasicAnimation)
        #expect(installed.keyPath == "opacity")
        #expect(installed.fromValue as? Double == 1)
        #expect(installed.toValue as? Double == 0.35)
        #expect(installed.autoreverses && installed.repeatCount == .infinity)

        // A marker in the installed copy detects replacement, not just equal configuration.
        let marker = try #require(installed.copy() as? CABasicAnimation)
        marker.beginTime = 123
        layer.add(marker, forKey: "own")
        host.setAnimation(fade, key: "own")
        #expect(layer.animation(forKey: "own")?.beginTime == 123)

        let changed = LayerAnimation(keyPath: "opacity", from: 1, to: 0.6, duration: 1.2,
                                     autoreverses: true, easing: .linear)
        host.setAnimation(changed, key: "own")
        let replacement = try #require(layer.animation(forKey: "own") as? CABasicAnimation)
        #expect(replacement.toValue as? Double == 0.6)
        #expect(replacement.duration == 1.2)
        #expect(replacement.beginTime != 123)
        #expect(layer.animationKeys() == ["own"])

        host.setAnimation(nil, key: "own")
        #expect(layer.animation(forKey: "own") == nil)
    }

    @Test func aDiscardedAnimationIsInstalledAgain() throws {
        let content = NSView()
        let host = OwnLayer<Text>.Host(content, fade)
        let layer = try #require(content.layer)
        layer.removeAnimation(forKey: "own")
        host.setAnimation(fade, key: "own")
        #expect(layer.animation(forKey: "own") != nil)
    }

    @Test func pausingAndResumingPreserveLocalTime() throws {
        let view = LayerAnimationView(frame: .zero)
        view.wantsLayer = true
        let layer = try #require(view.layer)
        view.setPlaybackPaused(true, at: 100)
        #expect(layer.speed == 0)
        #expect(layer.convertTime(150, from: nil) == 100)
        // A repeated pause cannot overwrite the saved phase.
        view.setPlaybackPaused(true, at: 175)
        view.setPlaybackPaused(false, at: 200)
        #expect(layer.speed == 1)
        #expect(layer.convertTime(200, from: nil) == 100)
        #expect(layer.convertTime(201, from: nil) == 101)
    }

    @Test func attachmentOcclusionAncestorHidingAndDetachmentControlPlayback() {
        let content = NSView()
        let host = OwnLayer<Text>.Host(content, fade)
        #expect(host.playbackPaused)
        let window = window(visible: true)
        let parent = NSView(frame: window.contentView!.bounds)
        window.contentView = parent
        parent.addSubview(host)
        #expect(!host.playbackPaused)

        window.testVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(host.playbackPaused)
        window.testVisible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!host.playbackPaused)

        parent.isHidden = true
        #expect(host.playbackPaused)
        parent.isHidden = false
        #expect(!host.playbackPaused)
        host.removeFromSuperview()
        #expect(host.playbackPaused)
        #expect(content.layer?.animation(forKey: "own") != nil)
        parent.addSubview(host)
        #expect(!host.playbackPaused)

        host.stopAnimation()
        #expect(content.layer?.animation(forKey: "own") == nil)
        window.contentView = nil
    }

    @Test func wrapperFitsItsContentAndDoesNotInterceptClicksOrHideItsAccessibleChild() {
        let text = NSTextField(labelWithString: "Working")
        // A label created outside a visible app isn't necessarily an AX element by default.
        // Establish a real accessible child before testing whether the wrapper preserves it.
        text.setAccessibilityElement(true)
        text.setAccessibilityRole(.staticText)
        let window = window(visible: true)
        let plain = NSView(frame: window.contentView!.bounds)
        window.contentView = plain
        plain.addSubview(text)
        #expect(text.isAccessibilityElement())
        #expect(plain.accessibilityChildren()?.contains { ($0 as? NSView) === text } == true)

        let host = OwnLayer<Text>.Host(text, nil)
        plain.addSubview(host)
        host.frame = CGRect(x: 0, y: 0, width: 140, height: 30)
        host.layout()
        #expect(text.frame == host.bounds)
        #expect(host.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(!host.isAccessibilityElement())
        #expect(text.isAccessibilityElement())
        #expect(host.accessibilityChildren()?.contains { ($0 as? NSView) === text } == true)
        window.contentView = nil
    }

    @Test func arcUpdatesGeometryWithoutDuplicatingItsAnimation() throws {
        let arc = SpinningArc.Turning.Arc()
        arc.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        arc.lineWidth = 2
        arc.layout()
        let layer = try #require(arc.animatedLayer as? CAShapeLayer)
        #expect(layer.path?.boundingBox == CGRect(x: 1, y: 1, width: 16, height: 16))
        #expect(layer.lineWidth == 2)
        #expect(layer.animationKeys() == ["turn"])
        #expect(arc.hitTest(.zero) == nil)
        arc.frame.size = CGSize(width: 30, height: 30)
        arc.lineWidth = 4
        arc.layout()
        #expect(layer.path?.boundingBox == CGRect(x: 2, y: 2, width: 26, height: 26))
        #expect(layer.animationKeys() == ["turn"])
        arc.stopAnimation()
        #expect(layer.animationKeys()?.isEmpty ?? true)
    }

    @Test(arguments: [0, 1, 2])
    func motionPreferencesControlHostCreation(mode: Int) {
        let content = VStack {
            SpinningArc()
            Text("Working").font(.system(size: 13)).foregroundStyle(Color.primary)
                .pulse(low: 0.35, period: 0.8)
        }
        .environment(\.hiddenTab, mode == 1)
        // This SDK exposes the public key as read-only; its underscored fixture key is writable.
        .environment(\._accessibilityReduceMotion, mode == 2)
        let hosted = NSHostingView(rootView: content)
        let window = window(visible: true)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        #expect(hosted.fittingSize.width > 0)
        #expect(containsAnimationHost(hosted) == (mode == 0))
        window.contentView = nil
    }

    private func containsAnimationHost(_ view: NSView) -> Bool {
        view is LayerAnimationView || view.subviews.contains(where: containsAnimationHost)
    }
}

@MainActor
private final class VisibilityWindow: NSWindow {
    var testVisible = false
    override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
}
