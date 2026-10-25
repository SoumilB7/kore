import AppKit
import Testing
@testable import KoreUI

@MainActor @Suite("Themed options", .serialized)
struct OptionsMenuTests {
    init() { _ = NSApplication.shared }

    @MainActor private final class ContextText: NSTextView {
        var calls = 0
        @objc func contextAction(_ sender: Any?) { calls += 1 }
    }

    @MainActor private final class LazyItems: NSObject, NSMenuDelegate {
        var updates = 0
        func menuNeedsUpdate(_ menu: NSMenu) {
            updates += 1
            if menu.items.isEmpty {
                let item = NSMenuItem(title: "Loaded child", action: nil, keyEquivalent: "")
                item.state = .on
                menu.addItem(item)
            }
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                        timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @Test func escapeWithoutAnOpenPeekIsHarmless() {
        EditorTextView().cancelOperation(nil)
    }

    @Test(arguments: [true, false])
    func placementsStayInsideTheirWindow(flipped: Bool) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        for point in [CGPoint.zero, CGPoint(x: 399, y: 299), CGPoint(x: 200, y: 150)] {
            let placed = OptionsMenu.fitting(point: point, size: CGSize(width: 280, height: 500), bounds: bounds, flipped: flipped)
            #expect(bounds.contains(placed))
            #expect(placed.width > 0 && placed.height > 0)
        }
    }

    @Test func disabledItemsSubmenusAndDismissalKeepTheirActions() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let menu = OptionsMenu()
        var calls = 0
        defer { menu.close(); window.contentView = nil }
        menu.show([OptionItem("Disabled", enabled: false) { calls += 100 }, .rule,
                   OptionItem("Group", children: [OptionItem("Child", checked: true) { calls += 1 }])],
                  at: CGPoint(x: 395, y: 290), in: window, source: "test")
        menu.choose(0)
        #expect(calls == 0 && menu.items.count == 3)
        menu.choose(2)
        #expect(menu.parents.count == 1 && menu.items.first?.checked == true)
        menu.back()
        #expect(menu.parents.isEmpty && menu.items.count == 3)
        menu.choose(2)
        menu.choose(0)
        #expect(calls == 1 && menu.items.isEmpty)
        menu.show([OptionItem("Choice") {}], at: .zero, in: window, source: "test")
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(menu.items.isEmpty)
    }

    @Test func outsideSecondaryClickDismissesAndAllowsRetargeting() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let menu = OptionsMenu()
        defer { menu.close(); window.contentView = nil }
        menu.show([OptionItem("Choice") {}], at: CGPoint(x: 100, y: 200), in: window, source: "test")
        #expect(!menu.retargetContextClick(try click(window, at: CGPoint(x: 120, y: 180))))
        #expect(menu.items.count == 1)
        #expect(menu.retargetContextClick(try click(window, at: CGPoint(x: 20, y: 20))))
        #expect(menu.items.isEmpty)
    }

    @Test func nativeActionsKeepTheirOriginalResponderAfterFocusMoves() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let first = ContextText(frame: CGRect(x: 0, y: 0, width: 240, height: 280))
        let second = ContextText(frame: CGRect(x: 250, y: 0, width: 240, height: 280))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        #expect(!window.isKeyWindow)
        #expect(window.makeFirstResponder(first))
        let menu = OptionsMenu(), native = NSMenu()
        native.addItem(NSMenuItem(title: "Action", action: #selector(ContextText.contextAction(_:)), keyEquivalent: ""))
        defer { menu.close(); window.contentView = nil }
        #expect(menu.showNative(native, event: try click(window, at: CGPoint(x: 20, y: 20)), view: first))
        #expect(menu.items.first?.enabled == true)
        #expect(window.firstResponder === first)
        #expect(window.makeFirstResponder(second))
        menu.choose(0)
        #expect(first.calls == 1 && second.calls == 0)
    }

    @Test func nativeSubmenusLoadBeforeTheirParentIsPresented() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let menu = OptionsMenu(), native = NSMenu(), child = NSMenu(), loader = LazyItems()
        native.autoenablesItems = false
        child.autoenablesItems = false
        child.delegate = loader
        let parent = NSMenuItem(title: "Group", action: nil, keyEquivalent: "")
        parent.submenu = child
        native.addItem(parent)
        defer { menu.close(); window.contentView = nil }
        let view = try #require(window.contentView)
        #expect(menu.showNative(native, event: try click(window, at: CGPoint(x: 20, y: 20)), view: view))
        #expect(loader.updates == 1)
        #expect(menu.items.first?.children.first?.title == "Loaded child")
        #expect(menu.items.first?.children.first?.checked == true)
    }

    @Test func textContextSelectsTheClickedWordAndPreservesAnExistingSelection() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let text = ContextText(frame: CGRect(x: 0, y: 0, width: 480, height: 280))
        text.string = "first second third"
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        window.contentView?.addSubview(text)
        defer { window.contentView = nil }
        let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        func point(_ index: Int) -> NSPoint {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return text.convert(NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y), to: nil)
        }
        text.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(OptionsMenu.prepareTextContext(text, event: try click(window, at: point(2))))
        #expect(text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(OptionsMenu.prepareTextContext(text, event: try click(window, at: point(8))))
        #expect(text.selectedRange() == NSRange(location: 6, length: 6))
        #expect(window.firstResponder === text)
    }
}
