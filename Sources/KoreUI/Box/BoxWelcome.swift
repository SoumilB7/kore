import AppKit
import HostClient
import LinkProtocol
import SwiftUI

/// Where the Welcome is: this Mac, or a box. The title row's box button toggles between this Mac
/// and the box last shown; the switcher picks one.
struct WelcomeSwitch: Equatable {
    /// The box shown; nil: this Mac.
    var place: String?
    /// The box the button goes back to.
    var lastBox: String?
    /// Add a box…'s field is open, with what's typed.
    var adding: String?

    /// The box button: back to this Mac, else to the last box (or the first one); with no box,
    /// Add a box… opens.
    mutating func toggle(boxes: [String]) {
        if place != nil {
            place = nil
            return
        }
        guard let box = lastBox.flatMap({ boxes.contains($0) ? $0 : nil }) ?? boxes.first else {
            adding = ""
            return
        }
        show(box)
    }

    mutating func show(_ box: String?) {
        place = box
        if let box { lastBox = box }
        adding = nil
    }

    /// A box forgotten while it's shown: back to this Mac.
    mutating func removed(_ box: String) {
        if place == box { place = nil }
        if lastBox == box { lastBox = nil }
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
}

/// The Welcome's switcher, at its top: This Mac | each box | +. A box's right-click: Set up
/// agents…, Check again, Remove. + is Add a box…: a field, the SSH hosts it could be under it.
struct WelcomeSwitcher: View {
    @Binding var state: WelcomeSwitch
    @FocusState private var typing: Bool
    @StateObject private var anchors = Held<[String: NSView]>([:])

    private var list: BoxList { .shared }

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.xxs) {
                segment("This Mac", key: "mac", on: state.place == nil, dot: nil) { state.show(nil) }
                ForEach(list.boxes) { box in
                    segment(box.alias, key: box.alias, on: state.place == box.alias, dot: box.dotState) { state.show(box.alias) }
                        .background(BoxAnchor { [anchors] view in anchors.value[box.alias] = view })
                        .koreContextMenu("box-row") { menu(box) }
                }
                if state.adding == nil {
                    Button {
                        state.adding = ""
                    } label: {
                        Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary)
                            .frame(width: Layout.Options.row, height: Layout.Options.row).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popupAwareHelp("Add a box…")
                    .storyID(StoryID.Boxes.add, press: { state.adding = "" })
                }
            }
            .padding(Space.xxs)
            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control + Space.xxs))
            if let text = state.adding { adding(text) }
        }
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
        items.append(OptionItem("Remove", destructive: true, children: [OptionItem("Forget \(box.alias) on this Mac", destructive: true) {
            BoxList.shared.remove(box.alias)
            state.removed(box.alias)
        }]))
        return items
    }

    private func adding(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BoxAliasField(text: Binding(get: { text }, set: { state.adding = $0 }), add: add) { state.adding = nil }
                .storyID(StoryID.Boxes.field)
            ForEach(list.suggestions(text).prefix(5), id: \.self) { alias in
                Button { add(alias) } label: {
                    Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                        .padding(.horizontal, Space.sm)
                        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.xs)
        .frame(width: Size.Box.popupWidth)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
    }

    private func add(_ typed: String) {
        guard let alias = BoxList.alias(typed) else { return }
        list.add(alias)
        state.show(alias)
        Task { await list.probe(alias) }
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
    /// The Welcome's rows for this box: its folders, then the chats open in them (each opens its
    /// folder's window there, the chat in front).
    @MainActor func welcomeItems(open: @escaping @MainActor (BoxPlace, String?) -> Void) -> [WelcomeItem] {
        let connection = BoxList.shared.link(alias)
        // The folders last opened first, then the rest as the box lists them.
        let recent = BoxBinding.recents(alias)
        let ordered = folders.enumerated().sorted { a, b in
            let (x, y) = (recent.firstIndex(of: a.element.path) ?? Int.max, recent.firstIndex(of: b.element.path) ?? Int.max)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var items = ordered.map { folder in
            let place = BoxPlace(alias: alias, folder: folder.path)
            let window = connection.windows.first { $0.id == folder.windowId }?.path ?? folder.path
            let parent = (window as NSString).deletingLastPathComponent
            return WelcomeItem(
                id: "folder:" + folder.path, symbol: "folder", title: folder.name, detail: parent,
                help: folder.missing == true ? "Missing on \(alias): \(folder.path)" : folder.path, missing: folder.missing == true,
                story: StoryID.Boxes.folder(folder.path)
            ) { open(place, nil) }
        }
        for folder in folders where folder.missing != true {
            for chat in connection.chats(in: folder.path).prefix(Layout.Welcome.recentsShown) {
                let place = BoxPlace(alias: alias, folder: folder.path)
                items.append(WelcomeItem(
                    id: "chat:" + chat.id, symbol: "bubble.left", title: chat.title.isEmpty ? "New chat" : chat.title, detail: folder.name,
                    help: chat.title, story: StoryID.Boxes.chat(chat.id)
                ) { open(place, chat.id) })
            }
        }
        return items
    }
}

extension BoxBinding {
    /// A box's folders by when their windows last opened, newest first (the Welcome's order).
    static func recents(_ alias: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "boxRecents." + alias) ?? []
    }

    static func opened(alias: String, folder: String, defaults: UserDefaults = .standard) {
        let list = [folder] + recents(alias, defaults: defaults).filter { $0 != folder }
        defaults.set(Array(list.prefix(20)), forKey: "boxRecents." + alias)
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
