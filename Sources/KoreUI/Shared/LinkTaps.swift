import AppKit
import Observation

/// Where Kore meets the local link (the KoreLink module, `z-docs/link-protocol.md`). While no
/// companion is linked, `on` is false and every hook costs one branch; nothing else exists.
@MainActor
package enum LinkTaps {
    /// A companion is linked: chat events and transcript changes are handed to the link.
    package static var on = false
    /// Every event a chat applies, once its stores have it, while `on`.
    package static var event: ((Chat, ChatEvent) -> Void)?
    /// The doorbell: the app sets it at launch; `AppDelegate`'s Apple Event handler calls it on
    /// a ring. Nothing runs until then.
    package static var doorbell: ((_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) -> Void)?
    /// Ends the link as Kore quits, while a companion is allowed.
    package static var quit: (() -> Void)?
    /// The companion's entries in "/" while it's allowed this run; nil before the first Allow.
    package static var slash: (() -> [SlashCommand])?
    /// One of those entries was chosen, by its name.
    package static var slashChosen: ((String) -> Void)?
}

/// What the title row shows while a companion is connected: its name, and the last few actions it
/// took this run (action and chat title, never text).
@MainActor @Observable
package final class LinkMark {
    package var name: String
    package var recent: [String] = []
    @ObservationIgnored package let disconnect: () -> Void

    /// How many actions the mark's popup lists.
    package static let recentMax = 6

    package init(name: String, disconnect: @escaping () -> Void) {
        self.name = name
        self.disconnect = disconnect
    }

    package func record(_ line: String) {
        recent.insert(line, at: 0)
        if recent.count > Self.recentMax { recent.removeLast(recent.count - Self.recentMax) }
    }

    /// The mark's one-line hover.
    package var line: String { "\(name) linked" }
}

extension Workspace {
    /// Shows or clears the link's mark in every open window.
    package static func showLinkMark(_ mark: LinkMark?) {
        for workspace in all.allObjects where workspace.linkMark !== mark { workspace.linkMark = mark }
    }
}

extension StoryID {
    package enum Link {
        /// The title row's mark while linked; a click opens its popup.
        package static let mark = StoryID(.titlebar, "link")
        package static let popup = StoryID(.titlebar, "link.popup")
        package static let disconnect = popup.part(.close)
        /// The Allow card a ring shows, and its buttons.
        package static let card = StoryID(.welcome, "link.card")
        package static let allow = card.part(.allow)
        package static let deny = card.part(.deny)
    }
}
