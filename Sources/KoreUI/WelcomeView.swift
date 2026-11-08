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

    private var place: String? { switcher.value.place }
    private var showsBoxes: Bool { !BoxList.shared.boxes.isEmpty || sshHosts.value }

    var body: some View {
        let items = items
        VStack(spacing: Layout.Welcome.sectionGap) {
            VStack(spacing: Space.sm) {
                if showsBoxes { WelcomeSwitcher(state: $switcher.value).padding(.bottom, Space.md) }
                BrandMark(height: Layout.Welcome.markHeight)
                    .padding(.bottom, Space.lg)
                Text(place ?? "Kore")
                    .font(Chrome.display)
                    .foregroundStyle(Theme.text)
                if let place {
                    BoxWelcomeLine(alias: place)
                } else {
                    Text("Open a folder to start")
                        .font(Chrome.body)
                        .foregroundStyle(Theme.secondary)
                }
            }

            Button {
                openFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .buttonStyle(SubtleButtonStyle(prominent: true))

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
        .padding(.vertical, Layout.Welcome.paddingV)
        .padding(.horizontal, Layout.Welcome.paddingH)
        .frame(width: Layout.Welcome.width)
        .frame(minHeight: Layout.Welcome.minHeight)
        // The window takes the content's full height (with .contentSize), so nothing is cut off.
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if let model = browser.value {
                ZStack {
                    Theme.background.opacity(0.5).contentShape(Rectangle()).onTapGesture { browser.value = nil }
                    BoxFolderBrowser(model: model, close: { browser.value = nil }) { path in add(path, on: model.alias) }
                }
            }
        }
        // The box button, where a folder window's title row has it: after the traffic lights. A
        // click switches the Welcome between this Mac and a box.
        .overlay(alignment: .topLeading) {
            Group { if showsBoxes { WelcomeBoxButton(on: place != nil) { toggle() } } }
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
            sshHosts.value = !BoxList.shared.suggestions().isEmpty
            if monitor.value == nil { monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key($0) } }
            app.welcomeTakesKeys = true
        }
        .onDisappear {
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

    /// The rows: this Mac's recent folders, or the box's folders and chats.
    private var items: [WelcomeItem] {
        if let place {
            return BoxList.shared.box(place)?.welcomeItems { box, chat in
                BoxBinding.open(box, chat: chat, openWindow: openWindow)
                dismissWindow(id: KoreApp.welcomeID)
            } ?? []
        }
        return app.recents.map { folder in
            WelcomeItem(
                id: folder.path, symbol: "folder", title: folder.lastPathComponent, detail: folder.deletingLastPathComponent().abbreviatedPath,
                help: folder.path, story: StoryID.Welcome.recent(folder.path)
            ) { open(folder) }
        }
    }

    private func toggle() {
        OptionsMenu.shared.close()
        switcher.value.toggle(boxes: BoxList.shared.boxes.map(\.alias))
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
        browser.value = BoxFolderBrowserModel(source: BoxList.shared.link(place))
    }

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
            return BoxFolderBrowser.key(event, model: model, typing: typing) { browser.value = nil } ? nil : event
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

/// The title row's box button on the Welcome: lit while the Welcome stands on a box.
private struct WelcomeBoxButton: View {
    let on: Bool
    let action: @MainActor @Sendable () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let lit = hovered.value || on
        Button(action: action) {
            Image(systemName: "server.rack")
                .font(Chrome.bodyMedium)
                .foregroundStyle(lit ? Theme.text : Theme.secondary)
                .frame(width: Size.Box.welcomeButton, height: Size.Box.welcomeButton)
                .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .popupAwareHelp(on ? "This Mac" : "Boxes")
        .storyID(StoryID.Titlebar.boxes, press: action)
    }
}

private struct WelcomeRow: View {
    let item: WelcomeItem
    let lit: Bool

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
                Spacer(minLength: Space.xl)
                Text(item.detail)
                    .font(Chrome.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(Inset.row)
            .hoverFill(lit, Theme.Row.selected(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.missing)
        .help(item.help)
        .storyID(item.story, press: item.open)
    }
}
