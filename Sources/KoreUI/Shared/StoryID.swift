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
            search, changes, viewer, usage, welcome, terminal
    }

    package enum Part: String, Sendable, CaseIterable {
        case fork, copy, stop, close, chevron, open, cancel, allow, always, deny, approveplan, keepplanning, archive
        case next, previous, reload, keep, compare, field, toggle, replace, indent, lineendings, language, add, done
        case autoaccept, replaceall, ticks, reset, use, method, `switch`, credentials, choose, save, share, track, outside, extended
        case signIn = "signin", signOut = "signout"
        case `continue`, background, submit, other
        /// A chat tab's spinner: its turn runs, or it compacts.
        case working
        /// A tab whose turn is offline or stalled: ⚠ in its spinner's place.
        case stuck
        /// A list row's stand-in for the pointer entering it; there while it's lit; a popup
        /// button's keyboard focus ring.
        case hover, lit, focus
    }
}

// MARK: - The names (plan §3's table)

extension StoryID {
    package enum Titlebar {
        package static let explorer = StoryID(.titlebar, "explorer")
        package static let history = StoryID(.titlebar, "history")
        package static let agents = StoryID(.titlebar, "agents")
        /// ">_ 2": the chat's live background commands; opens the map at them.
        package static let commands = StoryID(.titlebar, "commands")
        package static let newtab = StoryID(.titlebar, "newtab")
        /// The Stay awake cup; its click turns it on or off.
        package static let awake = StoryID(.titlebar, "awake")
        /// A mode in the cup's menu, by `StayAwake.Mode`'s id; "off" is Turn Off.
        package static func awakeMode(_ id: String) -> StoryID { StoryID(.titlebar, "awake.mode", key: id) }
        /// `»N` after a strip that scrolls; its list of the tabs out of view, and a tab's row in it
        /// (its spinner `.part(.working)`, its ⚠ `.part(.stuck)`).
        package static let overflow = StoryID(.titlebar, "overflow")
        package static let hiddenTabs = StoryID(.titlebar, "overflow.list")
        package static func hiddenTab(_ id: UUID) -> StoryID { StoryID(.titlebar, "overflow.tab", key: id.uuidString) }
        /// The number `»N` shows, as its key.
        package static func hiddenCount(_ n: Int) -> StoryID { StoryID(.titlebar, "overflow.count", key: String(n)) }
        /// The active tab's name before a strip of tabs too narrow for theirs.
        package static let tabName = StoryID(.titlebar, "tabname")
    }

    package enum Tabs {
        /// A chat or agent tab; `.part(.close)` is its close button.
        package static func tab(_ id: UUID) -> StoryID { StoryID(.tabs, "tab", key: id.uuidString) }
        package static func file(_ relativePath: String) -> StoryID { StoryID(.tabs, "file", key: relativePath) }
        /// The strip the tabs scroll in.
        package static let strip = StoryID(.tabs, "strip")
    }

    package enum NewTab {
        package static func provider(_ id: String) -> StoryID { StoryID(.newtab, "provider", key: id) }
    }

    package enum Composer {
        package static let field = StoryID(.composer, "field")
        package static let send = StoryID(.composer, "send")
        /// The ring beside Send at a plan's limit: the draft goes when the limit resets.
        package static let sendAtReset = StoryID(.composer, "sendatreset")
        package static let stop = StoryID(.composer, "stop")
        package static let attach = StoryID(.composer, "attach")
        package static let slash = StoryID(.composer, "slash")
        /// The mode pill and the model chip, each opening its picker.
        package static let mode = StoryID(.composer, "mode")
        package static let model = StoryID(.composer, "model")
        /// The model picker; its effort slider is `effort`, a level on it `effortLevel`.
        package static let models = StoryID(.composer, "models")
        /// A version chip, by the model's id; a family's name (which picks its newest), by the
        /// family; a row's "…" chip, by the family.
        package static func modelChip(_ id: String) -> StoryID { StoryID(.composer, "models.chip", key: id) }
        package static func modelFamily(_ name: String) -> StoryID { StoryID(.composer, "models.family", key: name) }
        package static func modelFold(_ name: String) -> StoryID { StoryID(.composer, "models.more", key: name) }
        package static let effort = StoryID(.composer, "effort")
        package static func effortLevel(_ level: String) -> StoryID { StoryID(.composer, "effort.level", key: level) }
        /// The model picker's fast mode switch.
        package static let fastMode = StoryID(.composer, "fastmode")
        /// The mode popup, and its rows by the mode's id (Codex's Plan switch by "plan").
        package static let modes = StoryID(.composer, "modes")
        package static func modeRow(_ id: String) -> StoryID { StoryID(.composer, "modes.row", key: id) }
        package static let context = StoryID(.composer, "context")
        /// The command chip before the text.
        package static let chip = StoryID(.composer, "chip")
        /// A row of the slash menu, by the command's name.
        package static func command(_ name: String) -> StoryID { StoryID(.composer, "command", key: name) }
        /// The usage popup; `.part(.open)` is its "Manage usage" link, `.part(.extended)` the button
        /// to its extended view, `.part(.reset)` its count of full resets, which unfolds them.
        package static let usage = StoryID(.composer, "usage")
        /// The Account popup; its action row's parts: `.signIn` (Sign in, Try again), `.method`
        /// (the ⌄), `.switch`, `.signOut`, then `.allow` / `.cancel` (the question's Yes and No,
        /// and Cancel during a sign-in), `.copy` (Copy link, Copy code).
        package static let account = StoryID(.composer, "account")
        /// A field of its key row or platform form, by name ("key", "region", "apikey"); its
        /// form's Credentials picker is `account.part(.credentials)`, the key file's Choose…
        /// `.part(.choose)`, Save `.part(.save)`.
        package static func accountField(_ name: String) -> StoryID { StoryID(.composer, "account.field", key: name) }
        /// A row of the methods the ⌄ unfolds in the card, by its path ("3rd-party platform",
        /// "3rd-party platform/Amazon Bedrock…"); a group's row discloses its own.
        package static func accountMethod(_ path: String) -> StoryID { StoryID(.composer, "account.method", key: path) }
        /// A login in the card's list, by its id ("main" for main): Switch is `.part(.switch)`,
        /// Remove `.part(.cancel)`; "add" is Add account.
        package static func accountLogin(_ id: String) -> StoryID { StoryID(.composer, "account.login", key: id) }
        /// A choice a form's picker unfolds, by the picker and the choice ("credentials/apiKey",
        /// "profile/dev").
        package static func accountChoice(_ picker: String, _ value: String) -> StoryID {
            StoryID(.composer, "account.choice", key: picker + "/" + value)
        }
        /// One of its limits, by its title; `.part(.track)` is its bar, `.part(.share)` Kore's
        /// hatched stretch of it.
        package static func usageLimit(_ title: String) -> StoryID { StoryID(.composer, "usage.limit", key: title) }
        /// One of its full resets, by the credit's id (empty for the one row of a count alone);
        /// `.part(.use)` asks, then `.part(.allow)` / `.part(.cancel)` answer.
        package static func usageReset(_ id: String?) -> StoryID { StoryID(.composer, "usage.reset", key: id ?? "") }
        /// An empty chat's "Import a chat" line (also the drop target's).
        package static let importLine = StoryID(.composer, "import")
        /// The import picker; its search field `.part(.field)`, Choose file… `.part(.choose)`,
        /// Import `.part(.add)`, Sign in `.part(.signIn)`, Try again `.part(.reload)`.
        package static let importer = StoryID(.composer, "importer")
        /// One of its chats, by session id (a file's by its path).
        package static func importRow(_ id: String) -> StoryID { StoryID(.composer, "importer.row", key: id) }
        /// A message waiting for the turn to end; `.part(.cancel)` takes it back.
        package static func queued(_ id: UUID) -> StoryID { StoryID(.composer, "queued", key: id.uuidString) }
    }

    /// The Usage popup's extended view: its card (`.part(.close)` its ×, `.part(.outside)` its
    /// Outside Kore row), its limits (the picker) by title, and the chats of the picked one.
    package enum UsageModal {
        package static let card = StoryID(.usage, "modal")
        package static func limit(_ title: String) -> StoryID { StoryID(.usage, "limit", key: title) }
        package static func chat(_ id: String) -> StoryID { StoryID(.usage, "chat", key: id) }
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
        /// A fenced code block, by its place in its markdown; `.part(.copy)` is its Copy.
        package static func code(_ path: [Int]) -> StoryID { StoryID(.transcript, "code", key: path.map(String.init).joined(separator: ".")) }
        package static let earlier = StoryID(.transcript, "earlier")
        /// The active feedback row, including delivery before the CLI acknowledges a turn.
        package static let spinner = StoryID(.transcript, "spinner")
        /// A stalled turn's spinner row: Retry and Stop.
        package static let stalledRetry = StoryID(.transcript, "stalled-retry")
        package static let stalledStop = StoryID(.transcript, "stalled-stop")
        /// A refused login's notice, by its turn; `.part(.signIn)` is its Sign in.
        package static func signIn(_ turn: String) -> StoryID { StoryID(.transcript, "signin", key: turn) }
        /// A limit notice's "Continues at …", by its turn; `.part(.cancel)` is its ×.
        package static func continues(_ turn: String) -> StoryID { StoryID(.transcript, "continues", key: turn) }
        /// A turn that failed while the Mac slept, by its turn; `.part(.continue)` is its Continue.
        package static func slept(_ turn: String) -> StoryID { StoryID(.transcript, "slept", key: turn) }
        package static func compacted(_ entry: UUID) -> StoryID { StoryID(.transcript, "compacted", key: entry.uuidString) }
        package static func peer(_ entry: UUID) -> StoryID { StoryID(.transcript, "peer", key: entry.uuidString) }
    }

    package enum Approval {
        /// `.part(.allow)`, `.always`, `.deny`; a plan card's `.approveplan` (edits approved by hand),
        /// `.autoaccept` and `.keepplanning`; a question card's `.submit`.
        package static func card(_ id: String) -> StoryID { StoryID(.approval, key: id) }
        /// A question's Other, by the question's id; `.part(.field)` is what's typed under it.
        package static func other(_ question: String) -> StoryID { StoryID(.approval, "other", key: question) }
        /// A question's option, by the question's id and the option's label.
        package static func option(_ question: String, _ label: String) -> StoryID { StoryID(.approval, "option", key: question + "/" + label) }
    }

    package enum AgentMap {
        package static func row(_ agent: String) -> StoryID { StoryID(.agentmap, "row", key: agent) }
        /// The wires drawn behind an agent's row: its elbow and the spines passing it.
        package static func wires(_ agent: String) -> StoryID { StoryID(.agentmap, "wires", key: agent) }
        /// A closed group of ended agents, "done" or "stopped": its row opens and closes it.
        package static func ended(_ group: String) -> StoryID { StoryID(.agentmap, "ended", key: group) }
        /// The chat's own row, the root the running agents hang off.
        package static let chat = StoryID(.agentmap, "chat")
        /// A command's row in a BACKGROUND section: its click opens it; `.part(.stop)` asks to stop
        /// it, `.part(.allow)` is "Yes, stop", `.part(.cancel)` "No, go back", `.part(.background)`
        /// Run in background.
        package static func command(_ id: String) -> StoryID { StoryID(.agentmap, "command", key: id) }
        /// Stop all over a section's rows, with the same parts as a row's Stop.
        package static let stopAll = StoryID(.agentmap, "stopall")
        /// ">_ 2 still running after their agents" at the tree's foot.
        package static let outlived = StoryID(.agentmap, "outlived")
        /// "Show 34 more" under the finished rows.
        package static let moreCommands = StoryID(.agentmap, "morecommands")
        package static let doneCommands = StoryID(.agentmap, "donecommands")
        package static let open = StoryID(.agentmap, "open")
        package static let stop = StoryID(.agentmap, "stop")
        package static let close = StoryID(.agentmap, "close")
    }

    package enum Welcome {
        /// A recent folder, by its path.
        package static func recent(_ path: String) -> StoryID { StoryID(.welcome, "recent", key: path) }
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
        /// A renderer's column of rows (Markdown, a notebook).
        package static let rows = StoryID(.editor, "rows")
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
            Terminal.panel, Terminal.newShell, Terminal.close, Terminal.hide, Terminal.maximize, Terminal.sash, Terminal.output, Terminal.stop,
            Titlebar.explorer, Titlebar.history, Titlebar.agents, Titlebar.newtab, Titlebar.awake, Titlebar.overflow,
            Titlebar.hiddenTabs, Titlebar.tabName, Tabs.strip,
            Composer.field, Composer.send, Composer.stop, Composer.attach, Composer.slash, Composer.mode,
            Composer.model, Composer.models, Composer.effort, Composer.modes, Composer.context, Composer.chip, Composer.usage, Composer.usage.part(.open),
            Composer.usage.part(.reset), Composer.account, Composer.account.part(.signIn), Composer.account.part(.method),
            Composer.account.part(.switch), Composer.account.part(.signOut), Composer.account.part(.allow),
            Composer.account.part(.cancel), Composer.account.part(.copy), Composer.account.part(.credentials),
            Composer.account.part(.choose), Composer.account.part(.save),
            Transcript.earlier, Transcript.spinner,
            AgentMap.open, AgentMap.stop, AgentMap.close, AgentMap.chat, History.search,
            Explorer.newfile, Explorer.newfolder, Explorer.refresh, Explorer.collapse, Explorer.namefield,
            Explorer.filesTab, Explorer.searchTab,
            Editor.Find.field, Editor.Find.replaceField, Editor.Find.next, Editor.Find.previous, Editor.Find.close,
            Editor.Find.toggleReplace, Editor.Find.replace, Editor.Find.replaceAll, Editor.Find.ticks,
            Editor.Status.indent, Editor.Status.lineEndings, Editor.Status.language,
            Editor.Notice.reload, Editor.Notice.keep, Editor.Notice.compare, Editor.rendererToggle, Editor.rows,
            QuickOpen.field, Search.field, Search.include, Search.exclude, Changes.done, Viewer.close, Viewer.add,
        ]
        let keyed: [StoryID] = [
            StoryID(.tabs, "tab", key: k), StoryID(.tabs, "tab", key: k).part(.close), StoryID(.tabs, "file", key: k),
            StoryID(.newtab, "provider", key: k), StoryID(.composer, "queued", key: k),
            StoryID(.composer, "queued", key: k).part(.cancel),
            StoryID(.composer, "command", key: k), StoryID(.composer, "usage.limit", key: k), StoryID(.composer, "account.field", key: k),
            StoryID(.composer, "account.method", key: k), StoryID(.composer, "account.choice", key: k),
            StoryID(.composer, "models.chip", key: k), StoryID(.composer, "models.family", key: k),
            StoryID(.composer, "models.more", key: k), StoryID(.composer, "effort.level", key: k),
            StoryID(.composer, "modes.row", key: k),
            StoryID(.composer, "usage.reset", key: k), StoryID(.composer, "usage.reset", key: k).part(.use),
            StoryID(.composer, "usage.reset", key: k).part(.allow), StoryID(.composer, "usage.reset", key: k).part(.cancel),
            StoryID(.transcript, "user", key: k), StoryID(.transcript, "user", key: k).part(.copy),
            StoryID(.transcript, "user", key: k).part(.fork), StoryID(.transcript, "answer", key: k),
            StoryID(.transcript, "answer", key: k).part(.copy), StoryID(.transcript, "answer", key: k).part(.fork),
            StoryID(.transcript, "fold", key: k), StoryID(.transcript, "tool", key: k),
            StoryID(.transcript, "explored", key: k), StoryID(.transcript, "agent", key: k),
            StoryID(.transcript, "agent", key: k).part(.stop), StoryID(.transcript, "agent", key: k).part(.open),
            StoryID(.transcript, "changes", key: k), StoryID(.transcript, "compacted", key: k),
            StoryID(.transcript, "peer", key: k), StoryID(.transcript, "signin", key: k),
            StoryID(.transcript, "signin", key: k).part(.signIn),
            StoryID(.titlebar, "awake.mode", key: k), StoryID(.titlebar, "overflow.tab", key: k),
            StoryID(.titlebar, "overflow.count", key: k), StoryID(.transcript, "continues", key: k),
            StoryID(.transcript, "continues", key: k).part(.cancel), StoryID(.transcript, "slept", key: k),
            StoryID(.transcript, "slept", key: k).part(.continue),
            StoryID(.approval, key: k).part(.allow), StoryID(.approval, key: k).part(.always),
            StoryID(.approval, key: k).part(.deny), StoryID(.approval, key: k).part(.approveplan),
            StoryID(.approval, key: k).part(.keepplanning), StoryID(.approval, key: k).part(.autoaccept),
            StoryID(.approval, key: k).part(.submit), StoryID(.approval, "other", key: k),
            StoryID(.approval, "other", key: k).part(.field), StoryID(.approval, "option", key: k),
            StoryID(.agentmap, "row", key: k), StoryID(.agentmap, "wires", key: k), StoryID(.agentmap, "ended", key: k),
            StoryID(.terminal, "entry", key: k), StoryID(.terminal, "entry", key: k).part(.close),
            StoryID(.history, "row", key: k),
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
