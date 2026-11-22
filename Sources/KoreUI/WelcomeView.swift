import AppKit
import HostClient
import SwiftUI

/// Open Folder… and the recent folders: ↑ ↓ light one (as the pointer does) and Return opens it.
/// With a box, the Welcome can stand on it instead (the switcher at its top, or the title row's
/// box button): its name, its one line when there's something to do, its folders and chats, and
/// Open Folder… browsing the box.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The one lit row: the pointer's, or the keys'.
    @StateObject private var lit = Local<Int?>(nil)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)
    /// The SSH config names a host (read once): the box button can add it as a box.
    @StateObject private var sshHosts = Local(false)
    @StateObject private var switcher = Local(WelcomeSwitch())
    /// The box folder browser, while it's open.
    @StateObject private var browser = Local<BoxFolderBrowserModel?>(nil)
    /// The box whose link the Welcome holds while it shows it.
    @StateObject private var held = Held<HostConnection?>(nil)
    /// Bumped as a box folder leaves Recent (its list lives in the defaults).
    @StateObject private var forgets = Local(0)

    private var place: String? { switcher.value.place }

    /// The big title: "Kore" on this Mac, the box's name on a box (its key may be its KoreNet id).
    static func title(_ place: String?) -> String { place.map(NodeNames.name) ?? "Kore" }
    /// Open Folder… works here: always on this Mac; on a box once kore-host answers there.
    private var opensFolders: Bool { place.flatMap { BoxList.shared.box($0) }?.opensFolders ?? true }
    private var showsBoxes: Bool { !BoxList.shared.boxes.isEmpty || sshHosts.value }

    var body: some View {
        let items = items
        VStack(spacing: Layout.Welcome.sectionGap) {
            VStack(spacing: Space.sm) {
                if showsBoxes { WelcomeSwitcher(state: $switcher.value).padding(.bottom, Space.md) }
                BrandMark(height: Layout.Welcome.markHeight)
                    .padding(.bottom, Space.lg)
                // This Mac ⇄ a box: the name, its line and its list cross-fade.
                Group {
                    Text(Self.title(place))
                        .font(Chrome.display)
                        .foregroundStyle(Theme.text)
                    // The box's route now, as the link moves: "Kore's tailnet", "SSH (mybox-cf)".
                    if let place, let route = Devices.shared.boxRoute(place) {
                        Text(route.line).font(Chrome.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                            .help(route.help ?? "")
                            .storyID(StoryID.Boxes.route)
                    }
                    if let place {
                        BoxWelcomeLine(alias: place)
                    } else {
                        Text("Open a folder to start")
                            .font(Chrome.body)
                            .foregroundStyle(Theme.secondary)
                    }
                    // Kore's tailnet here or there not signed in: one quiet line, Sign in on it.
                    OwnCueLine(box: place, story: StoryID.Net.welcomeCue(place))
                        .frame(maxWidth: Layout.Welcome.contentWidth)
                }
                .id(place ?? "")
                .transition(.opacity)
            }

            Button {
                openFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .buttonStyle(SubtleButtonStyle(prominent: true))
            // A box being set up (or one that can't be reached) has no folders to browse yet.
            .disabled(!opensFolders)

            if !items.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Recent")
                        .font(Chrome.captionMedium)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.xxs)
                    // At most `recentsShown` rows tall, the rest a scroll away: the window keeps one size.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    WelcomeRow(item: item, lit: lit.value == index)
                                        .highlightRow(item.story, lit: lit.value == index) { lit.value = index }
                                        .koreContextMenu("welcome-recent") { Self.menu(item) }
                                        .id(index)
                                }
                            }
                        }
                        .scrollIndicators(items.count > Layout.Welcome.recentsShown ? .automatic : .never)
                        .frame(height: Layout.Welcome.recentsHeight(items.count))
                        .onChange(of: lit.value) { _, index in if let index { proxy.scrollTo(index) } }
                    }
                }
                .frame(width: Layout.Welcome.contentWidth)
                .id(place ?? "")
                .transition(.opacity)
            }

            if place == nil, let problem = app.cliProblem {
                Text(problem)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(width: Layout.Welcome.contentWidth)
            }
            if place == nil, let signedOut = app.signedOutLine {
                Text(signedOut)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: Layout.Welcome.contentWidth)
            }
        }
        .animation(Motion.fade, value: place)
        .padding(.vertical, Layout.Welcome.paddingV)
        .padding(.horizontal, Layout.Welcome.paddingH)
        .frame(width: Layout.Welcome.width)
        .frame(minHeight: Layout.Welcome.minHeight)
        // The window takes the content's full height (with .contentSize), so nothing is cut off.
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if let model = browser.value {
                ZStack {
                    Theme.background.opacity(0.5).contentShape(Rectangle()).onTapGesture { closeBrowser() }
                    BoxFolderBrowser(model: model, close: closeBrowser) { path in add(path, on: model.alias) }
                }
                .transition(.opacity)
            }
        }
        // KoreNet's devices, in the title row after the traffic lights (the switcher's chips
        // above go between this Mac and a box); its popup hangs under it.
        .overlay(alignment: .topLeading) {
            NetworkButton(size: Size.Box.welcomeButton)
                .padding(.leading, Size.Box.welcomeInset)
                .padding(.top, Space.xs)
                .ignoresSafeArea(.container, edges: .top)
        }
        .background(WindowReader { window.value = $0 })
        .onChange(of: place) { _, place in
            lit.value = nil
            browser.value = nil
            hold(place)
        }
        .onAppear {
            // Peers coming and going on the tailnet reach the switcher while it shows.
            Devices.shared.net?.hold("welcome", true)
            sshHosts.value = StorylineSeams.sshHosts?() ?? !BoxList.shared.suggestions().isEmpty
            if monitor.value == nil { monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key($0) } }
            app.welcomeTakesKeys = true
        }
        .onDisappear {
            Devices.shared.net?.hold("welcome", false)
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
            app.welcomeTakesKeys = false
            hold(nil)
        }
        .task {
            // A dev snapshot of this window when no folder is opened.
            if let folder = DevSnapshot.openFolder { open(folder) } else { DevSnapshot.captureIfRequested() }
            await app.checkCLI()
        }
    }

    /// The rows: this Mac's recent folders, or the box's, one per folder.
    private var items: [WelcomeItem] {
        if let place {
            _ = forgets.value
            return BoxList.shared.box(place)?.welcomeItems { box, chat in
                BoxBinding.open(box, chat: chat, openWindow: openWindow)
                dismissWindow(id: KoreApp.welcomeID)
            }.map { item in
                var item = item
                let folder = String(item.id.dropFirst("folder:".count))
                item.forget = { [forgets] in
                    BoxBinding.forget(alias: place, folder: folder)
                    forgets.value += 1
                }
                return item
            } ?? []
        }
        return app.recents.map { folder in
            var item = WelcomeItem(
                id: folder.path, symbol: "folder", title: folder.lastPathComponent, detail: folder.deletingLastPathComponent().abbreviatedPath,
                help: folder.path, story: StoryID.Welcome.recent(folder.path)
            ) { open(folder) }
            item.forget = { [app] in app.forgetRecent(folder) }
            return item
        }
    }

    /// A Recent row's right-click: Remove from Recent (the row only; the folder stays as it is).
    static func menu(_ item: WelcomeItem) -> [OptionItem] {
        guard let forget = item.forget else { return [] }
        return [OptionItem("Remove from Recent") { MainActor.assumeIsolated(forget) }]
    }

    /// The box shown keeps its link while the Welcome shows it (its folders, chats, GitHub's
    /// sign-in); asked fresh once.
    private func hold(_ place: String?) {
        if held.value?.alias == place { return }
        held.value?.release()
        held.value = nil
        guard let place else { return }
        let connection = BoxList.shared.link(place)
        connection.retain()
        held.value = connection
        Task { await BoxList.shared.probe(place) }
    }

    private func openFolder() {
        guard let place else {
            if let folder = app.chooseFolder() { open(folder) }
            return
        }
        withAnimation(Motion.fade) { browser.value = BoxFolderBrowserModel(source: BoxList.shared.link(place)) }
    }

    private func closeBrowser() { withAnimation(Motion.fade) { browser.value = nil } }

    private func open(_ folder: URL) {
        app.open(folder, openWindow: openWindow, dismissWindow: dismissWindow)
    }

    /// The browser's Open: the folder added to what the box serves, then its window.
    private func add(_ path: String, on alias: String) {
        Task {
            switch await BoxList.shared.addFolder(alias, path: path) {
            case .success(let folder):
                browser.value = nil
                BoxBinding.open(BoxPlace(alias: alias, folder: folder.path), chat: nil, openWindow: openWindow)
                dismissWindow(id: KoreApp.welcomeID)
            case .failure(let why):
                browser.value?.failed(why.message)
            }
        }
    }

    /// ↑ ↓ through the rows, stopping at the ends (from none, the first or the last), Return
    /// opens the lit one. This window's keys only; the browser's while it shows.
    private func key(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        let typing = window.firstResponder is NSTextView
        if let model = browser.value {
            return BoxFolderBrowser.key(event, model: model, typing: typing) { closeBrowser() } ? nil : event
        }
        let items = items
        guard !items.isEmpty, !typing, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        switch event.keyCode {
        case 125, 126:
            let step = event.keyCode == 125 ? 1 : -1
            lit.value = lit.value.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
            PointerGate.keyed()
        case 36, 76:
            guard let index = lit.value, items.indices.contains(index), !items[index].missing else { return event }
            items[index].open()
        default:
            return event
        }
        return nil
    }
}

private struct WelcomeRow: View {
    let item: WelcomeItem
    let lit: Bool
    /// The name's width on one line, and as drawn: cut short, its tooltip is the full path (else
    /// none, the row says it all).
    @StateObject private var full = Local<CGFloat>(0)
    @StateObject private var shown = Local<CGFloat>(0)

    var body: some View {
        Button(action: item.open) {
            HStack(spacing: Space.lg) {
                Image(systemName: item.symbol)
                    .font(Chrome.label)
                    .foregroundStyle(item.missing ? Theme.tertiary : Theme.secondary)
                Text(item.title)
                    .font(Chrome.bodyMedium)
                    .foregroundStyle(item.missing ? Theme.tertiary : Theme.text)
                    .lineLimit(1)
                    .background(alignment: .leading) {
                        Text(item.title).font(Chrome.bodyMedium).fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [full] in full.value = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [shown] in shown.value = $0 }
                Spacer(minLength: Space.xl)
                Text(item.detail)
                    .font(Chrome.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, Inset.row.leading)
            // One pitch exactly (less the gap): the list's height counts on it, so five rows
            // never scroll a few points and clip the first.
            .frame(height: Layout.Welcome.recentPitch - Space.xs)
            .hoverFill(lit, Theme.Row.selected(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.missing)
        .help(item.missing || full.value > shown.value + 0.5 ? item.help : "")
        .storyID(item.story, press: item.open)
    }
}
