import AppKit
import KoreUI
import src

/// A long chat left mid-way up, then hidden under two other chats' tabs: a switch between those
/// two leaves it out of drawing (none of its texts drawn again, none of its layers marked to draw,
/// torn down or made anew), its rows kept as they were drawn; back, on its very first frame, the
/// same row is at the same place (±2 pt) and drawn. Twice, so a tab hidden again after its return
/// is left out again too.
final class TabComesBackInPlace: Storyline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }

    override func steps() -> [any Step] {
        [OpenFolder()] + TabComesBackDrawn.chat(1) + [
            // Mid-way up: well away from both ends.
            Scroll(.answer(turn: TabComesBackDrawn.turns), to: .by(-6000)), WaitIdle(),
            NotePlace(),
        ] + TabComesBackDrawn.chat(2) + TabComesBackDrawn.chat(3) + [
            WaitIdle(), SwitchOver(hidden: 1, to: 2), ShowFirstFrame(tab: 1),
            WaitIdle(), NotePlace(), Press(.tab(3)), WaitIdle(), SwitchOver(hidden: 1, to: 2), ShowFirstFrame(tab: 1),
        ]
    }

    /// The row the reader left in view, its top in the window, and how many layers its
    /// transcript drew.
    @MainActor
    final class Left {
        var place: (id: StoryID, top: CGFloat)?
        var layers = 0
    }

    @MainActor static func layers(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) }
    }

    @MainActor static func layerIDs(_ layer: CALayer) -> Set<ObjectIdentifier> {
        (layer.sublayers ?? []).reduce(into: [ObjectIdentifier(layer)]) { $0.formUnion(layerIDs($1)) }
    }

    /// Its layers marked to draw at the next display.
    @MainActor static func marked(_ layer: CALayer) -> Int {
        (layer.needsDisplay() ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + marked($1) }
    }

    /// The active chat's place: its first message or answer in view.
    struct NotePlace: Step {
        var label: String { "Note the row in view and where it is" }

        func run(_ story: StoryContext) async throws {
            let chat = try story.activeChat()
            let left = story.stash(Left.self) { Left() }
            left.place = SwitchTab.rowIDs(chat).lazy.compactMap { id in SwitchTab.top(of: id).map { (id, $0) } }.first
            left.layers = TabComesBackInPlace.layers(chat.storyTranscript.scrollView?.documentView?.layer)
            guard left.place != nil else { throw StoryFailure.expectation("a message or answer in view") }
        }
    }

    /// A switch to tab `to`, laid out and drawn, with tab `hidden` under it all along: its
    /// transcript is still in the window with its rows drawn, and the switch draws none of its
    /// texts again, marks none of its layers to draw, and makes or drops none of them.
    struct SwitchOver: Step {
        let hidden: Int
        let to: Int
        var label: String { "Switch to tab \(to): tab \(hidden)'s transcript out of its drawing, its rows kept" }

        func run(_ story: StoryContext) async throws {
            guard let workspace = story.app.workspace, let content = story.window?.contentView,
                workspace.tabs.indices.contains(hidden - 1), let chat = workspace.tabs[hidden - 1].chat
            else { throw StoryFailure.modelMissing("tab \(hidden)'s chat") }
            guard workspace.activeTab !== workspace.tabs[hidden - 1], workspace.activeTab !== workspace.tabs[to - 1] else {
                throw StoryFailure.expectation("tab \(hidden) and tab \(to) both hidden before the switch")
            }
            let left = story.stash(Left.self) { Left() }
            guard let scroll = chat.storyTranscript.scrollView, scroll.window != nil, let root = scroll.documentView?.layer else {
                throw StoryFailure.expectation("tab \(hidden)'s transcript kept in the window")
            }
            let before = TabComesBackInPlace.layerIDs(root)
            guard TextDraws.watch(root) else { throw StoryFailure.expectation("tab \(hidden)'s texts drawn in layers of their own") }
            TextDraws.drawn = []
            workspace.storySelect(tabAt: to - 1)
            content.layoutSubtreeIfNeeded()
            let marked = TabComesBackInPlace.marked(root)
            let after = TabComesBackInPlace.layerIDs(root)
            content.displayIfNeeded()
            CATransaction.flush()
            let redrawn = TextDraws.drawn.filter(after.contains).count
            TextDraws.drawn = []
            guard redrawn == 0 else {
                throw StoryFailure.expectation("tab \(hidden) left out of the switch: \(redrawn) of its texts drawn again")
            }
            guard workspace.activeTab === workspace.tabs[to - 1] else { throw StoryFailure.expectation("tab \(to) shown") }
            guard after.count * 2 >= left.layers else {
                throw StoryFailure.expectation("tab \(hidden)'s rows kept drawn (\(after.count) layers, \(left.layers) when it showed)")
            }
            guard marked == 0, before == after else {
                throw StoryFailure.expectation(
                    "tab \(hidden) left out of the switch: \(marked) of its \(after.count) layers marked to draw, \(before.subtracting(after).count) dropped, \(after.subtracting(before).count) made")
            }
        }
    }

    /// Which text layers draw: SwiftUI draws each text into a layer of one class, whose
    /// `draw(in:)` this wraps, once, to note the layer before drawing as before.
    @MainActor
    enum TextDraws {
        static var drawn: [ObjectIdentifier] = []
        private static var wrapped: AnyClass?

        /// Wraps the draws of the text layers under `root`: false when it has none.
        static func watch(_ root: CALayer) -> Bool {
            guard let layer = first(under: root), let cls = object_getClass(layer) else { return false }
            if wrapped === cls { return true }
            guard wrapped == nil, let method = class_getInstanceMethod(cls, #selector(CALayer.draw(in:))) else { return false }
            typealias Draw = @convention(c) (CALayer, Selector, CGContext) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
            let note: @convention(block) (CALayer, CGContext) -> Void = { layer, context in
                MainActor.assumeIsolated { TextDraws.drawn.append(ObjectIdentifier(layer)) }
                original(layer, #selector(CALayer.draw(in:)), context)
            }
            method_setImplementation(method, imp_implementationWithBlock(note))
            wrapped = cls
            return true
        }

        private static func first(under layer: CALayer) -> CALayer? {
            if "\(type(of: layer))".hasSuffix("CGDrawingLayer") { return layer }
            for sub in layer.sublayers ?? [] { if let found = first(under: sub) { return found } }
            return nil
        }
    }

    /// Shows the tab, lays the window out and draws it once: that first frame has the tab's
    /// transcript visible, the noted row drawn in view, at the place it was left.
    struct ShowFirstFrame: Step {
        let tab: Int
        var label: String { "Show tab \(tab): its first frame drawn, the row where it was" }

        func run(_ story: StoryContext) async throws {
            guard let workspace = story.app.workspace, let content = story.window?.contentView else { throw StoryFailure.modelMissing("the window") }
            let left = story.stash(Left.self) { Left() }
            guard let place = left.place else { throw StoryFailure.expectation("a noted place") }
            workspace.storySelect(tabAt: tab - 1)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let chat = workspace.activeTab.chat, workspace.activeTab === workspace.tabs[tab - 1],
                let scroll = chat.storyTranscript.scrollView, let document = scroll.documentView
            else { throw StoryFailure.expectation("tab \(tab)'s transcript shown") }
            let faded = scroll.isHiddenOrHasHiddenAncestor
                || sequence(first: scroll.layer, next: { $0?.superlayer }).contains { $0.map { $0.isHidden || $0.opacity < 0.01 } ?? false }
            let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
            let inView = SwitchTab.rowIDs(chat).filter { SwitchTab.top(of: $0) != nil }.count
            let top = SwitchTab.top(of: place.id)
            let at = top.map { "\(Int($0.rounded()))" } ?? "not in view"
            guard !faded, document.bounds.intersects(visible), inView > 0, let top, abs(top - place.top) <= 2 else {
                throw StoryFailure.expectation(
                    "first frame: \(faded ? "hidden" : "visible"), \(inView) rows in view, noted row at \(at) (was \(Int(place.top.rounded())))")
            }
        }
    }
}
