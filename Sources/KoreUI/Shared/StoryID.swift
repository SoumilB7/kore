import Foundation
import SwiftUI

/// An element's storyline name (phase 12 plan §3): `area.element[key].part`, lowercase and
/// dot-separated, keyed by Kore's own ids, never a screen position. Views tag themselves with
/// `.storyID(_:)` and locators look the same names up, both through these builders, so a name is
/// never spelled twice.
///
/// Keys: entries by `uuidString`; turns, tools, agents, approvals and sessions by the store's or
/// CLI's id as is; paths relative to the window's folder with `/`; lines 0-based; tabs by
/// `ChatTab.id`. A `]` in a key is written `%5D`.
package struct StoryID: Hashable, Sendable, CustomStringConvertible {
    package let raw: String
    package var description: String { raw }

    package init(_ area: Area, _ element: String? = nil, key: String? = nil) {
        var raw = area.rawValue
        if let element { raw += "." + element }
        if let key { raw += "[" + key.replacingOccurrences(of: "]", with: "%5D") + "]" }
        self.raw = raw
    }

    private init(raw: String) { self.raw = raw }

    /// A control inside this element: `.fork`, `.copy`, `.close`…; parts chain.
    package func part(_ part: Part) -> StoryID { StoryID(raw: raw + "." + part.rawValue) }

    package enum Area: String, Sendable, CaseIterable {
        case titlebar, tabs, newtab, composer, transcript, approval, agentmap, history, explorer, editor, quickopen,
            search, changes, viewer
    }

    package enum Part: String, Sendable, CaseIterable {
        case fork, copy, stop, close, chevron, open, cancel, allow, always, deny, approveplan, keepplanning, archive
        case next, previous, reload, keep, compare, field, toggle, replace, indent, lineendings, language, add, done
        case autoaccept, replaceall, ticks
    }
}

// MARK: - The names (plan §3's table)

extension StoryID {
    package enum Titlebar {
        package static let explorer = StoryID(.titlebar, "explorer")
        package static let history = StoryID(.titlebar, "history")
        package static let agents = StoryID(.titlebar, "agents")
        package static let newtab = StoryID(.titlebar, "newtab")
    }

    package enum Tabs {
        /// A chat or agent tab; `.part(.close)` is its close button.
        package static func tab(_ id: UUID) -> StoryID { StoryID(.tabs, "tab", key: id.uuidString) }
        package static func file(_ relativePath: String) -> StoryID { StoryID(.tabs, "file", key: relativePath) }
    }

    package enum NewTab {
        package static func provider(_ id: String) -> StoryID { StoryID(.newtab, "provider", key: id) }
    }

    package enum Composer {
        package static let field = StoryID(.composer, "field")
        package static let send = StoryID(.composer, "send")
        package static let stop = StoryID(.composer, "stop")
        package static let attach = StoryID(.composer, "attach")
        package static let slash = StoryID(.composer, "slash")
        package static let mode = StoryID(.composer, "mode")
        package static let model = StoryID(.composer, "model")
        package static let effort = StoryID(.composer, "effort")
        package static let context = StoryID(.composer, "context")
        /// The command chip before the text.
        package static let chip = StoryID(.composer, "chip")
        /// A row of the slash menu, by the command's name.
        package static func command(_ name: String) -> StoryID { StoryID(.composer, "command", key: name) }
        /// A message waiting for the turn to end; `.part(.cancel)` takes it back.
        package static func queued(_ id: UUID) -> StoryID { StoryID(.composer, "queued", key: id.uuidString) }
    }

    package enum Transcript {
        /// `.part(.copy)` and `.part(.fork)` on both.
        package static func user(_ entry: UUID) -> StoryID { StoryID(.transcript, "user", key: entry.uuidString) }
        package static func answer(_ entry: UUID) -> StoryID { StoryID(.transcript, "answer", key: entry.uuidString) }
        package static func fold(_ turn: String) -> StoryID { StoryID(.transcript, "fold", key: turn) }
        package static func tool(_ id: String) -> StoryID { StoryID(.transcript, "tool", key: id) }
        package static func explored(_ id: String) -> StoryID { StoryID(.transcript, "explored", key: id) }
        /// `.part(.stop)` and `.part(.open)`.
        package static func agent(_ id: String) -> StoryID { StoryID(.transcript, "agent", key: id) }
        package static func changes(_ turn: String) -> StoryID { StoryID(.transcript, "changes", key: turn) }
        package static let earlier = StoryID(.transcript, "earlier")
        package static func compacted(_ entry: UUID) -> StoryID { StoryID(.transcript, "compacted", key: entry.uuidString) }
        package static func peer(_ entry: UUID) -> StoryID { StoryID(.transcript, "peer", key: entry.uuidString) }
    }

    package enum Approval {
        /// `.part(.allow)`, `.always`, `.deny`; a plan card's `.approveplan` (edits approved by hand),
        /// `.autoaccept` and `.keepplanning`.
        package static func card(_ id: String) -> StoryID { StoryID(.approval, key: id) }
    }

    package enum AgentMap {
        package static func row(_ agent: String) -> StoryID { StoryID(.agentmap, "row", key: agent) }
        /// The wires drawn behind an agent's row: its elbow and the spines passing it.
        package static func wires(_ agent: String) -> StoryID { StoryID(.agentmap, "wires", key: agent) }
        /// The stopped agents' group: its row opens and closes it.
        package static let stopped = StoryID(.agentmap, "stopped")
        /// The group of the background agents that have finished: its row opens and closes it.
        package static let done = StoryID(.agentmap, "done")
        /// The background agents' group's label, over its rows.
        package static let background = StoryID(.agentmap, "background")
        package static let open = StoryID(.agentmap, "open")
        package static let stop = StoryID(.agentmap, "stop")
        package static let close = StoryID(.agentmap, "close")
    }

    package enum History {
        package static let search = StoryID(.history, "search")
        /// `.part(.archive)`.
        package static func row(_ session: String) -> StoryID { StoryID(.history, "row", key: session) }
    }

    package enum Explorer {
        package static func row(_ relativePath: String) -> StoryID { StoryID(.explorer, "row", key: relativePath) }
        package static let newfile = StoryID(.explorer, "newfile")
        package static let newfolder = StoryID(.explorer, "newfolder")
        package static let refresh = StoryID(.explorer, "refresh")
        package static let collapse = StoryID(.explorer, "collapse")
        package static let namefield = StoryID(.explorer, "namefield")
        package static let filesTab = StoryID(.explorer, "tab.files")
        package static let searchTab = StoryID(.explorer, "tab.search")
    }

    package enum Editor {
        /// The text view.
        package static func text(_ relativePath: String) -> StoryID { StoryID(.editor, key: relativePath) }
        package static func gutterFold(_ line: Int) -> StoryID { StoryID(.editor, "gutter.fold", key: String(line)) }
        package static func foldChip(_ line: Int) -> StoryID { StoryID(.editor, "foldchip", key: String(line)) }

        package enum Find {
            package static let field = StoryID(.editor, "find").part(.field)
            package static let replaceField = StoryID(.editor, "find").part(.replace).part(.field)
            package static let next = StoryID(.editor, "find").part(.next)
            package static let previous = StoryID(.editor, "find").part(.previous)
            package static let close = StoryID(.editor, "find").part(.close)
            /// The chevron that shows or hides the replace row.
            package static let toggleReplace = StoryID(.editor, "find").part(.toggle)
            package static let replace = StoryID(.editor, "find").part(.replace)
            package static let replaceAll = StoryID(.editor, "find").part(.replaceall)
            /// The matches' ticks beside the scroller.
            package static let ticks = StoryID(.editor, "find").part(.ticks)
        }

        package enum Status {
            package static let indent = StoryID(.editor, "status").part(.indent)
            package static let lineEndings = StoryID(.editor, "status").part(.lineendings)
            package static let language = StoryID(.editor, "status").part(.language)
        }

        package enum Notice {
            package static let reload = StoryID(.editor, "notice").part(.reload)
            package static let keep = StoryID(.editor, "notice").part(.keep)
            package static let compare = StoryID(.editor, "notice").part(.compare)
        }

        package static let rendererToggle = StoryID(.editor, "renderer").part(.toggle)
    }

    package enum QuickOpen {
        package static let field = StoryID(.quickopen, "field")
        package static func row(_ relativePath: String) -> StoryID { StoryID(.quickopen, "row", key: relativePath) }
    }

    package enum Search {
        package static let field = StoryID(.search, "field")
        package static let include = StoryID(.search, "include")
        package static let exclude = StoryID(.search, "exclude")
        package static func result(_ relativePath: String, line: Int) -> StoryID {
            StoryID(.search, "result", key: "\(relativePath):\(line)")
        }
    }

    package enum Changes {
        package static func file(_ relativePath: String) -> StoryID { StoryID(.changes, "file", key: relativePath) }
        package static let done = StoryID(.changes, "done")
    }

    package enum Viewer {
        package static let close = StoryID(.viewer, "close")
        package static let add = StoryID(.viewer, "add")
    }

    /// Every fixed name, for the not-found report's near misses and the grammar test (names with
    /// a key are listed with `<key>`).
    package static let all: [String] = {
        let k = "<key>"
        let fixed: [StoryID] = [
            Titlebar.explorer, Titlebar.history, Titlebar.agents, Titlebar.newtab,
            Composer.field, Composer.send, Composer.stop, Composer.attach, Composer.slash, Composer.mode,
            Composer.model, Composer.effort, Composer.context, Composer.chip, Transcript.earlier,
            AgentMap.open, AgentMap.stop, AgentMap.close, History.search,
            Explorer.newfile, Explorer.newfolder, Explorer.refresh, Explorer.collapse, Explorer.namefield,
            Explorer.filesTab, Explorer.searchTab,
            Editor.Find.field, Editor.Find.replaceField, Editor.Find.next, Editor.Find.previous, Editor.Find.close,
            Editor.Find.toggleReplace, Editor.Find.replace, Editor.Find.replaceAll, Editor.Find.ticks,
            Editor.Status.indent, Editor.Status.lineEndings, Editor.Status.language,
            Editor.Notice.reload, Editor.Notice.keep, Editor.Notice.compare, Editor.rendererToggle,
            QuickOpen.field, Search.field, Search.include, Search.exclude, Changes.done, Viewer.close, Viewer.add,
        ]
        let keyed: [StoryID] = [
            StoryID(.tabs, "tab", key: k), StoryID(.tabs, "tab", key: k).part(.close), StoryID(.tabs, "file", key: k),
            StoryID(.newtab, "provider", key: k), StoryID(.composer, "queued", key: k),
            StoryID(.composer, "queued", key: k).part(.cancel),
            StoryID(.composer, "command", key: k),
            StoryID(.transcript, "user", key: k), StoryID(.transcript, "user", key: k).part(.copy),
            StoryID(.transcript, "user", key: k).part(.fork), StoryID(.transcript, "answer", key: k),
            StoryID(.transcript, "answer", key: k).part(.copy), StoryID(.transcript, "answer", key: k).part(.fork),
            StoryID(.transcript, "fold", key: k), StoryID(.transcript, "tool", key: k),
            StoryID(.transcript, "explored", key: k), StoryID(.transcript, "agent", key: k),
            StoryID(.transcript, "agent", key: k).part(.stop), StoryID(.transcript, "agent", key: k).part(.open),
            StoryID(.transcript, "changes", key: k), StoryID(.transcript, "compacted", key: k),
            StoryID(.transcript, "peer", key: k),
            StoryID(.approval, key: k).part(.allow), StoryID(.approval, key: k).part(.always),
            StoryID(.approval, key: k).part(.deny), StoryID(.approval, key: k).part(.approveplan),
            StoryID(.approval, key: k).part(.keepplanning), StoryID(.approval, key: k).part(.autoaccept),
            StoryID(.agentmap, "row", key: k), StoryID(.agentmap, "wires", key: k), StoryID(.history, "row", key: k),
            StoryID(.history, "row", key: k).part(.archive), StoryID(.explorer, "row", key: k),
            StoryID(.editor, key: k), StoryID(.editor, "gutter.fold", key: k), StoryID(.editor, "foldchip", key: k),
            StoryID(.quickopen, "row", key: k), StoryID(.search, "result", key: k), StoryID(.changes, "file", key: k),
        ]
        return (fixed + keyed).map(\.raw)
    }()
}

// MARK: - Tagging views

// Storylines register these (StoryRegistry.swift); `StoryHost.installed` is set only by a
// storyline host, so in the owner's app they cost an identifier at most.

extension View {
    /// Names this element for storylines (and gives it the accessibility identifier). `press`
    /// performs it without a pointer, for a control whose action isn't a plain click. Registered
    /// only while a storyline host runs; in the owner's app it's the identifier alone.
    package func storyID(_ id: StoryID, press: (@MainActor () -> Void)? = nil) -> some View {
        modifier(StoryTag(id: id.raw, press: press))
    }

    /// The optional form, for a view whose name depends on what it shows (a timeline row).
    package func storyID(_ id: StoryID?, press: (@MainActor () -> Void)? = nil) -> some View {
        modifier(StoryTag(id: id?.raw, press: press))
    }

    /// A part of this row with no view of its own until hover (Fork, Copy, "Open in tab"):
    /// registered for storylines only. In the owner's app it adds nothing.
    package func storyAction(_ id: StoryID, press: @escaping @MainActor () -> Void) -> some View {
        modifier(StoryPart(id: id.raw, press: press))
    }

    /// A drawn part with nothing to press (the agent map's wires): registered for storylines
    /// only, so they can find it. In the owner's app it adds nothing.
    package func storyMark(_ id: StoryID) -> some View {
        modifier(StoryPart(id: id.raw, press: nil))
    }
}

/// The identifier and the registration, as one modifier: its body is compiled once rather than
/// at every view that's named.
private struct StoryTag: ViewModifier {
    let id: String?
    let press: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        content.accessibilityIdentifier(id ?? "").background(StoryAnchor(id: id, press: press))
    }
}

/// A hidden part's registration: no identifier, which would replace its row's.
private struct StoryPart: ViewModifier {
    let id: String
    let press: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        content.background(StoryAnchor(id: id, press: press))
    }
}

/// Where a call site's registration lives: one concrete view, so the check for a storyline host
/// is made here once instead of as a branch in every view that's named. Empty in the owner's app.
package struct StoryAnchor: View {
    let id: String?
    let press: (@MainActor () -> Void)?

    package var body: some View {
        if StoryHost.installed, let id { StoryRegistrar(id: id, press: press) }
    }
}

extension NSView {
    /// The AppKit side: the editor's text view, and the gutter's and fold chips' elements.
    package func setStoryID(_ id: StoryID) {
        setAccessibilityIdentifier(id.raw)
        if StoryHost.installed { registerStory(id.raw) }
    }
}
