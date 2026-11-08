import AppKit
import HostClient
import LinkProtocol
import Observation
import SwiftUI

/// The Welcome's Open Folder… on a box: its folders listed over the link (`fs.list`), as Kore's
/// open-folder panel feels. It starts at the box's home; ↑ ↓ light a folder, Return goes into it,
/// ⌫ or ← go up, ⌘⇧. shows dotfiles; a path typed or pasted goes there. New Folder makes one
/// here; Open adds the lit folder (else this one, else the path typed) to what the box serves.
@MainActor @Observable
final class BoxFolderBrowserModel {
    /// The folder shown, as the box normalised it; nil until the home is listed.
    private(set) var path: String?
    private(set) var entries: [FileEntry] = []
    private(set) var more = false
    /// The lit folder, by name.
    var lit: String?
    private(set) var hidden = false
    private(set) var loading = false
    /// Why the last move or New Folder didn't go.
    private(set) var problem: String?
    /// The box's home, from the first listing: what `~` stands for.
    private(set) var home: String?

    @ObservationIgnored private let source: any BoxFileSource
    @ObservationIgnored private var asked = 0

    init(source: any BoxFileSource) { self.source = source }

    var alias: String { source.alias }

    /// The folders, in order: what ↑ ↓ step through (files show greyed and don't light).
    var folders: [FileEntry] { entries.filter(\.isFolder) }

    /// The path's parts, each with its folder: "/", "home", "me", …
    var crumbs: [(name: String, path: String)] {
        guard let path else { return [] }
        var out: [(String, String)] = [("/", "/")]
        var at = ""
        for part in path.split(separator: "/") {
            at += "/" + part
            out.append((String(part), at))
        }
        return out
    }

    /// The home first.
    func start() async {
        guard path == nil, !loading else { return }
        await go(nil)
    }

    /// Lists `to` (nil: the home); on a refusal the folder shown stays and the line says why.
    /// `lighting`: the entry to light once it's listed (where ⌫ came up from).
    func go(_ to: String?, lighting: String? = nil) async {
        asked += 1
        let ask = asked
        loading = true
        let result = await source.list(to.map(expand), hidden: hidden)
        guard ask == asked else { return }
        loading = false
        switch result {
        case .success(let listing):
            if path == nil, to == nil { home = listing.path }
            path = listing.path
            entries = listing.entries
            more = listing.more
            problem = nil
            lit = lighting.flatMap { name in folders.contains { $0.name == name } ? name : nil }
        case .failure(let why):
            problem = why.message
        }
    }

    /// `~` and `~/x` as the box's home.
    func expand(_ typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, typed == "~" || typed.hasPrefix("~/") else { return typed }
        return home + typed.dropFirst()
    }

    func up() async {
        guard let path, path != "/" else { return }
        await go((path as NSString).deletingLastPathComponent, lighting: (path as NSString).lastPathComponent)
    }

    /// Return: into the lit folder.
    func enter() async {
        guard let path, let lit else { return }
        await go(child(path, lit))
    }

    func step(_ by: Int) {
        let names = folders.map(\.name)
        guard !names.isEmpty else { return }
        let at = lit.flatMap { names.firstIndex(of: $0) }
        lit = names[at.map { min(max($0 + by, 0), names.count - 1) } ?? (by > 0 ? 0 : names.count - 1)]
    }

    func toggleHidden() async {
        hidden.toggle()
        if let path { await go(path, lighting: lit) }
    }

    /// New Folder: made here, then lit.
    func newFolder(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            problem = "A folder name, without /"
            return
        }
        switch await source.makeFolder(child(path, name)) {
        case .success: await go(path, lighting: name)
        case .failure(let why): problem = why.message
        }
    }

    /// What Open adds: the path typed (when it differs), else the lit folder, else this one.
    func target(typed: String) -> String? {
        let typed = expand(typed)
        if !typed.isEmpty, typed != path { return typed }
        guard let path else { return nil }
        return lit.map { child(path, $0) } ?? path
    }

    /// Open didn't go (the box refused the folder): why, in the browser's line.
    func failed(_ why: String) { problem = why }

    private func child(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }
}

/// The browser's card, over the Welcome: the crumbs, the list, the path field, New Folder,
/// Cancel and Open. Its keys come from the Welcome's (`key`).
struct BoxFolderBrowser: View {
    let model: BoxFolderBrowserModel
    let close: () -> Void
    let open: (String) -> Void
    @StateObject private var typed = Local("")
    @StateObject private var naming = Local<String?>(nil)
    @StateObject private var opening = Local(false)
    @FocusState private var field: Bool
    @FocusState private var nameField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            crumbs
            list
            if let problem = model.problem {
                Text(problem).font(Chrome.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            TextField("", text: $typed.value, prompt: Text(model.path ?? "Path on \(model.alias)").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Chrome.label)
                .focused($field)
                .fieldWell(focused: field)
                .onSubmit {
                    let to = typed.value
                    Task { await model.go(to) }
                }
            HStack(spacing: Space.sm) {
                if let name = naming.value {
                    TextField("", text: Binding(get: { name }, set: { naming.value = $0 }), prompt: Text("New folder").foregroundStyle(Theme.tertiary))
                        .textFieldStyle(.plain)
                        .font(Chrome.label)
                        .focused($nameField)
                        .fieldWell(focused: nameField)
                        .onSubmit { makeFolder() }
                        .onExitCommand { naming.value = nil }
                        .onAppear { nameField = true }
                    Button("Make") { makeFolder() }.smallButton()
                } else {
                    Button("New Folder") { naming.value = "" }.smallButton().disabled(model.path == nil)
                }
                Spacer(minLength: Space.sm)
                Button("Cancel", action: close).smallButton()
                Button("Open") { choose() }.smallButton(prominent: true)
                    .disabled(opening.value || model.target(typed: typed.value) == nil)
            }
        }
        .padding(Space.md)
        .frame(width: Layout.Welcome.contentWidth + Space.xxl)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .storyID(StoryID.Boxes.browser)
        .task { await model.start() }
        .onChange(of: model.path) { _, path in typed.value = path ?? "" }
    }

    private var crumbs: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "server.rack").font(Chrome.caption).foregroundStyle(Theme.tertiary)
            Text(model.alias).font(Chrome.label).foregroundStyle(Theme.secondary)
            ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary) }
                Button(crumb.name) { Task { await model.go(crumb.path) } }
                    .buttonStyle(.plain)
                    .font(Chrome.label)
                    .foregroundStyle(index == model.crumbs.count - 1 ? Theme.text : Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.loading { SpinningArc().frame(width: Size.spinner, height: Size.spinner) }
        }
        .frame(minHeight: Layout.Options.row)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries, id: \.name) { entry in
                        row(entry).id(entry.name)
                    }
                    if model.more {
                        Text("First \(LinkFiles.listMax.formatted()) shown").font(Chrome.caption).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                    }
                }
            }
            .frame(height: Layout.Welcome.recentsHeight(Layout.Welcome.recentsShown) + Layout.Welcome.recentPitch * 2)
            .onChange(of: model.lit) { _, lit in if let lit { proxy.scrollTo(lit) } }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        let lit = model.lit == entry.name
        return Button {
            guard entry.isFolder else { return }
            if NSApp.mouseClickCount >= 2 || lit {
                model.lit = entry.name
                Task { await model.enter() }
            } else {
                model.lit = entry.name
            }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: entry.isFolder ? "folder" : FileIcon.symbol(for: entry.name))
                    .font(Chrome.caption).foregroundStyle(entry.isFolder ? Theme.secondary : Theme.tertiary).frame(width: Size.Box.lead)
                Text(entry.name).font(Chrome.label).foregroundStyle(entry.isFolder ? Theme.text : Theme.tertiary).lineLimit(1)
                if entry.kind == .link { Image(systemName: "arrow.turn.up.right").font(Chrome.caption).foregroundStyle(Theme.tertiary) }
                Spacer(minLength: 0)
                if entry.isFolder { Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary) }
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
            .background(lit ? Theme.Row.selected(.surface) : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isFolder)
        .storyID(StoryID.Boxes.entry(entry.name))
    }

    private func makeFolder() {
        guard let name = naming.value else { return }
        naming.value = nil
        Task { await model.newFolder(name) }
    }

    private func choose() {
        guard let target = model.target(typed: typed.value) else { return }
        opening.value = true
        open(target)
    }

    /// The Welcome's keys while the browser shows; false when they aren't the browser's.
    static func key(_ event: NSEvent, model: BoxFolderBrowserModel, typing: Bool, close: () -> Void) -> Bool {
        if event.keyCode == 53 {
            // Esc: a field's own first.
            guard !typing else { return false }
            close()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command, .shift], event.charactersIgnoringModifiers == "." || event.keyCode == 47 {
            Task { await model.toggleHidden() }
            return true
        }
        guard !typing, flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.step(1)
        case 126: model.step(-1)
        case 36, 76: Task { await model.enter() }
        case 51, 123: Task { await model.up() }
        case 124: Task { await model.enter() }
        default: return false
        }
        return true
    }
}
