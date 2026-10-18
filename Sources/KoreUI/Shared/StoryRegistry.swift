import AppKit
import SwiftUI

/// Whether a storyline host is driving this process. `kore-storylines` sets it before the app
/// starts and it never changes after, so a view that branches on it keeps one shape for the life
/// of the app. In Kore it stays false and nothing below is ever used.
@MainActor
package enum StoryHost {
    package static var installed = false
}

/// The elements a storyline can act on, by StoryID (phase 12, §3): what is in a window right now,
/// with how to press it. SwiftUI builds no accessibility tree inside its own process, so this
/// stands in for one. Views register through `StoryRegistrar` (`.storyID`, `.storyAction`), and
/// AppKit pieces that draw their own parts (the gutter, fold chips) with `register(_:in:rect:press:)`.
///
/// Frames aren't tracked: an entry holds its view weakly and works its frame out when asked.
@MainActor
package enum StoryRegistry {
    package typealias Token = Int

    @MainActor
    package final class Entry {
        package let id: String
        package let token: Token
        fileprivate weak var view: NSView?
        /// The part's rect in the view's coordinates; nil means the whole view.
        fileprivate let rect: (() -> CGRect?)?
        package fileprivate(set) var press: (@MainActor () -> Void)?

        fileprivate init(id: String, token: Token, view: NSView, rect: (() -> CGRect?)?, press: (@MainActor () -> Void)?) {
            self.id = id
            self.token = token
            self.view = view
            self.rect = rect
            self.press = press
        }

        package var window: NSWindow? { view?.window }
        /// The view that registered: the registrar behind a SwiftUI element, or the AppKit view
        /// that draws the part.
        package var registeredView: NSView? { view }

        /// Where it is, in its window's base coordinates (what `NSEvent.locationInWindow` uses);
        /// nil once the view has left its window or the part isn't drawn.
        package var frame: CGRect? {
            guard let view, view.window != nil else { return nil }
            guard let local = rect.map({ $0() }) ?? view.bounds else { return nil }
            return view.convert(local, to: nil)
        }
    }

    /// Registrations by id, oldest first: the latest one still in a window answers for the id.
    private static var entries: [String: [Entry]] = [:]
    private static var next: Token = 0

    /// Only a shown window's: a window an earlier storyline closed keeps its views until it's
    /// freed, and its element of the same name would answer for this one's.
    package static func entry(_ id: String) -> Entry? {
        entries[id]?.last { $0.window?.isVisible == true }
    }

    /// Every id with an entry in a window, sorted.
    package static var ids: [String] {
        entries.compactMap { id, list in list.contains { $0.window != nil } ? id : nil }.sorted()
    }

    /// The registered ids that share the most leading segments with `id` (its parent and
    /// siblings first), for a not-found report: a wrong name and a missing control read differently.
    package static func nearest(to id: String, limit: Int = 8) -> [String] {
        let all = ids
        let segments = id.split(separator: ".")
        func shared(_ other: String) -> Int { zip(segments, other.split(separator: ".")).prefix { $0 == $1 }.count }
        let best = all.map(shared).max() ?? 0
        guard best > 0 else { return [] }
        return Array(all.filter { shared($0) == best }.prefix(limit))
    }

    package static func register(
        _ id: String, in view: NSView, rect: (() -> CGRect?)? = nil, press: (@MainActor () -> Void)? = nil
    ) -> Token {
        next += 1
        entries[id, default: []].append(Entry(id: id, token: next, view: view, rect: rect, press: press))
        return next
    }

    package static func unregister(_ token: Token) {
        for (id, list) in entries where list.contains(where: { $0.token == token }) {
            let rest = list.filter { $0.token != token }
            entries[id] = rest.isEmpty ? nil : rest
            return
        }
    }

    /// What each AppKit view registered as a whole, so a new name replaces the old one.
    private static var wholeViews: [ObjectIdentifier: Token] = [:]

    fileprivate static func registerWhole(_ view: NSView, _ id: String, press: (@MainActor () -> Void)?) {
        if let old = wholeViews[ObjectIdentifier(view)] { unregister(old) }
        wholeViews[ObjectIdentifier(view)] = register(id, in: view, press: press)
    }

    fileprivate static func update(_ token: Token, press: (@MainActor () -> Void)?) {
        for list in entries.values {
            if let entry = list.first(where: { $0.token == token }) { entry.press = press; return }
        }
    }
}

extension NSView {
    /// Registers this AppKit view as a whole (the editor's text view) under `raw`, replacing
    /// what it registered before. Storyline hosts only: callers check `StoryHost.installed`.
    @MainActor package func registerStory(_ raw: String, press: (@MainActor () -> Void)? = nil) {
        StoryRegistry.registerWhole(self, raw, press: press)
    }
}

/// The host-only half of `.storyID` and `.storyAction`: a background that covers its view,
/// registers while it's in a window, and never takes a click.
package struct StoryRegistrar: NSViewRepresentable {
    let id: String
    let press: (@MainActor () -> Void)?

    package init(id: String, press: (@MainActor () -> Void)? = nil) {
        self.id = id
        self.press = press
    }

    package func makeNSView(context: Context) -> NSView { Registrar(id: id, press: press) }

    package func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Registrar)?.update(id: id, press: press)
    }

    package static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? Registrar)?.leave()
    }

    private final class Registrar: NSView {
        private var id: String
        private var press: (@MainActor () -> Void)?
        private var token: StoryRegistry.Token?

        init(id: String, press: (@MainActor () -> Void)?) {
            self.id = id
            self.press = press
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { leave() } else { enter() }
        }

        func update(id: String, press: (@MainActor () -> Void)?) {
            self.press = press
            if id != self.id {
                self.id = id
                leave()
                if window != nil { enter() }
            } else if let token {
                StoryRegistry.update(token, press: press)
            }
        }

        private func enter() {
            guard token == nil else { return }
            token = StoryRegistry.register(id, in: self, press: press)
        }

        func leave() {
            if let token { StoryRegistry.unregister(token) }
            token = nil
        }
    }
}
