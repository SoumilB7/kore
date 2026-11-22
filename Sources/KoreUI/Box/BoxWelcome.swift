import AppKit
import HostClient
import LinkProtocol
import SwiftUI

/// Where the Welcome is: this Mac, or a box. The title row's box button toggles between this Mac
/// and the box last shown; the switcher picks one.
struct WelcomeSwitch: Equatable {
    /// The box shown; nil: this Mac.
    var place: String?
    /// Add a box…'s field is open, with what's typed.
    var adding: String?

    mutating func show(_ box: String?) {
        place = box
        adding = nil
    }

    /// The field's text as typed. Once an alias is picked the field is gone for good: the text a
    /// field hands back as it goes (its end of editing) doesn't open it again over the set-up.
    mutating func typed(_ text: String) {
        if adding != nil { adding = text }
    }

    /// A box forgotten while it's shown: back to this Mac.
    mutating func removed(_ box: String) {
        if place == box { place = nil }
    }
}

/// One row of the Welcome's list: a recent folder on this Mac, or a box's folder or chat.
struct WelcomeItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let help: String
    var missing = false
    var story: StoryID
    let open: @MainActor () -> Void
    /// Remove from Recent: forgets the row only.
    var forget: (@MainActor () -> Void)?
}

/// The Welcome's switcher, at its top: This Mac | each box | +. A box's right-click: Set up
/// agents…, Check again, Remove. + is Add a box…: a field, the SSH hosts it could be under it.
struct WelcomeSwitcher: View {
    @Binding var state: WelcomeSwitch
    @FocusState private var typing: Bool
    @StateObject private var anchors = Held<[String: NSView]>([:])
    @StateObject private var plusAnchor = Held<NSView?>(nil)
    @StateObject private var barAnchor = Held<NSView?>(nil)

    private var list: BoxList { .shared }

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.xxs) {
                segment("This Mac", key: "mac", on: state.place == nil, dot: nil) { state.show(nil) }
                ForEach(list.boxes) { box in
                    segment(NodeNames.name(box.alias), key: box.alias, on: state.place == box.alias, dot: box.dotState) { state.show(box.alias) }
                        .background(BoxAnchor { [anchors] view in anchors.value[box.alias] = view })
                        .koreContextMenu("box-row") { menu(box) }
                }
                if state.adding == nil {
                    Button {
                        plus()
                    } label: {
                        Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary)
                            .frame(width: Layout.Options.row, height: Layout.Options.row).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popupAwareHelp("Add a box…")
                    .background(BoxAnchor { [plusAnchor] in plusAnchor.value = $0 })
                    .storyID(StoryID.Boxes.add, press: { plus() })
                }
            }
            .padding(Space.xxs)
            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control + Space.xxs))
            .background(BoxAnchor { [barAnchor] in barAnchor.value = $0 })
            if let text = state.adding { adding(text) }
        }
    }

    /// "+": the add-box choices Devices' "Add a box" offers too (the boxes on the tailnet, Use
    /// SSH…, New box… while the release has it); the alias field at once when Use SSH… is all
    /// there is to choose.
    private func plus() {
        let offers = Devices.shared.picture().net == .running || HostRelease.shared.hasScript == true
        guard offers, let anchor = plusAnchor.value, let window = anchor.window else {
            state.adding = ""
            return
        }
        if NetPopupHost.shared.isShowing("add") { return NetPopupHost.shared.close() }
        let ready: @MainActor (String) -> Void = { [self] key in
            if BoxList.shared.box(key) == nil { BoxList.shared.add(key) }
            state.show(key)
        }
        let bar = barAnchor.value
        NetPopupHost.shared.show(
            "add",
            WelcomeAddList(
                useSSH: {
                    NetPopupHost.shared.close()
                    state.adding = ""
                },
                newBox: {
                    NetPopupHost.shared.close()
                    NetPopupHost.shared.show("newbox", NewBoxPopup(ready: ready), in: window, under: bar ?? anchor, edge: .center)
                }, ready: ready),
            in: window, under: anchor, below: bar, edge: .leading)
    }

    private func segment(_ title: String, key: String, on: Bool, dot: StatusDot.State?, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let dot { StatusDot(state: dot) }
                Text(title).font(Chrome.label).foregroundStyle(on ? Theme.text : Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, Space.sm)
            .frame(minHeight: Layout.Options.row)
            .background(on ? Theme.background : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .storyID(StoryID.Boxes.place(key), press: action)
    }

    /// Set up agents… once kore-host answers, Check again, and Remove (a step in: it forgets the box
    /// here and leaves the box as it is).
    private func menu(_ box: BoxList.Box) -> [OptionItem] {
        var items: [OptionItem] = []
        if box.status == .ready {
            items.append(OptionItem("Set up agents…") { [anchors] in BoxCard.shared.showAgents(box.alias, under: anchors.value[box.alias]) })
        }
        items.append(OptionItem("Check again") { Task { await BoxList.shared.act(.tryAgain, on: box.alias) } })
        items.append(.rule)
        let enrolled = NodeDirectory.shared.entry(forKey: HostConnection.current(box.alias))?.enrolled ?? false
        let forget = DevicesWords.remove(NodeNames.name(box.alias), kind: .box, enrolled: enrolled)
        items.append(OptionItem("Remove", destructive: true, children: [OptionItem(forget, destructive: true) {
            BoxList.shared.remove(box.alias)
            state.removed(box.alias)
        }]))
        return items
    }

    private func adding(_ text: String) -> some View {
        BoxAliasEntry(
            text: Binding(get: { text }, set: { state.typed($0) }), story: StoryID.Boxes.field,
            suggestions: list.suggestions(text), add: add
        ) { state.adding = nil }
        .padding(Space.xs)
        .frame(width: Size.Box.popupWidth)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
    }

    private func add(_ typed: String) {
        guard let alias = BoxList.alias(typed) else { return }
        state.show(alias)
        Devices.shared.adder.addBox(alias)
    }
}

/// A box's one quiet line on the Welcome, under its name, only when there's something to do: its
/// status and action (Set up, Start, Update, Set up agents, N differences · Fix), else GitHub when
/// it isn't signed in there.
struct BoxWelcomeLine: View {
    let alias: String

    var body: some View {
        let box = BoxList.shared.box(alias)
        let connection = BoxList.shared.link(alias)
        if let note = box?.note {
            BoxNoteLine(note: note, alias: alias)
        } else if NetJoinLine.shows(alias) {
            NetJoinLine(alias: alias)
        } else if connection.ghSignedIn == false || connection.accounts.line(BoxAccounts.gitHub).step != .idle {
            BoxAccountLine(title: "GitHub", key: BoxAccounts.gitHub, accounts: connection.accounts, takesPaste: false) {
                connection.accounts.signInGitHub()
            }
            .frame(width: Layout.Welcome.contentWidth)
        } else {
            Text("Open a folder to start").font(Chrome.body).foregroundStyle(Theme.secondary)
        }
    }
}

extension BoxList.Box {
    /// The Welcome's rows for this box, as on this Mac: one per folder, the folders last opened
    /// first, then the rest as the box lists them; a folder taken off Recent stays off until it's
    /// opened again. Opening one opens its window, where its chats are (History).
    @MainActor func welcomeItems(open: @escaping @MainActor (BoxPlace, String?) -> Void) -> [WelcomeItem] {
        let byPath = Dictionary(folders.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return BoxBinding.recentFolders(alias, folders: folders.map(\.path)).compactMap { path in
            guard let folder = byPath[path] else { return nil }
            let place = BoxPlace(alias: alias, folder: folder.path)
            return WelcomeItem(
                id: "folder:" + folder.path, symbol: "folder", title: folder.name, detail: (folder.path as NSString).deletingLastPathComponent,
                help: folder.missing == true ? "Missing on \(NodeNames.name(alias)): \(folder.path)" : folder.path, missing: folder.missing == true,
                story: StoryID.Boxes.folder(folder.path)
            ) { open(place, nil) }
        }
    }
}

extension BoxBinding {
    /// A box's folders by when their windows last opened, newest first (the Welcome's order).
    static func recents(_ alias: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "boxRecents." + alias) ?? []
    }

    /// Folders taken off a box's Recent (Remove from Recent), until opened again.
    static func forgotten(_ alias: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "boxRecentsForgotten." + alias) ?? []
    }

    static func opened(alias: String, folder: String, defaults: UserDefaults = .standard) {
        let list = [folder] + recents(alias, defaults: defaults).filter { $0 != folder }
        defaults.set(Array(list.prefix(20)), forKey: "boxRecents." + alias)
        let forgotten = forgotten(alias, defaults: defaults)
        if forgotten.contains(folder) { defaults.set(forgotten.filter { $0 != folder }, forKey: "boxRecentsForgotten." + alias) }
    }

    /// Remove from Recent on a box: the row is forgotten here; nothing on the box changes.
    static func forget(alias: String, folder: String, defaults: UserDefaults = .standard) {
        defaults.set(recents(alias, defaults: defaults).filter { $0 != folder }, forKey: "boxRecents." + alias)
        let forgotten = forgotten(alias, defaults: defaults)
        if !forgotten.contains(folder) { defaults.set(forgotten + [folder], forKey: "boxRecentsForgotten." + alias) }
    }

    /// The box's Recent, one path per folder: what was recorded (older Kore kept places inside a
    /// folder too) moved into the folder holding it, deduplicated, newest first; then the folders
    /// never opened here; less those taken off. The tidied list is written back once it differs.
    static func recentFolders(_ alias: String, folders: [String], defaults: UserDefaults = .standard) -> [String] {
        let stored = recents(alias, defaults: defaults)
        let migrated = migrated(stored, into: folders)
        if migrated != stored, !folders.isEmpty { defaults.set(migrated, forKey: "boxRecents." + alias) }
        let off = Set(forgotten(alias, defaults: defaults))
        var seen = Set(migrated)
        let rest = folders.filter { seen.insert($0).inserted }
        return (migrated + rest).filter { !off.contains($0) }
    }

    /// Each recorded path as the box folder that holds it (the deepest), once, in order; paths in
    /// no folder are dropped.
    static func migrated(_ recents: [String], into folders: [String]) -> [String] {
        let deepest = folders.sorted { $0.count > $1.count }
        var seen = Set<String>()
        return recents.compactMap { path in
            deepest.first { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }.filter { seen.insert($0).inserted }
    }

    /// Chats to put in front once their box window opens, by its key.
    static var pendingChat: [String: String] = [:]

    static func key(_ place: BoxPlace) -> String { "box:" + place.alias + ":" + (place.folder ?? "") }

    /// Opens a box folder's window, a chat of it in front: at once when it's open, else once
    /// its tabs are made.
    static func open(_ place: BoxPlace, chat: String?, openWindow: OpenWindowAction) {
        let key = key(place)
        if let chat {
            if let workspace = Workspace.all.allObjects.first(where: { !$0.isClosed && $0.box?.key == key }) {
                workspace.box?.select(chat)
            } else {
                pendingChat[key] = chat
            }
        }
        openWindow(value: place)
    }

    /// The tab of a box chat in this window, in front.
    func select(_ chatId: String) {
        guard let workspace, let tab = workspace.tabs.first(where: { ($0.chat?.services as? BoxChatServices)?.chatId == chatId }) else { return }
        workspace.select(tab)
    }
}
