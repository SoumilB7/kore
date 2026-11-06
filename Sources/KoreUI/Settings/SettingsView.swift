import SwiftUI

/// Kore's Settings window (⌥⌘, or the title row's cog): sections on the left, the section on the
/// right, laid out like ghostty-config. A theme is previewed live and kept with Save; the rest
/// keep as they're changed.
struct SettingsView: View {
    static let id = "settings"

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", newChats = "New Chats"
        case text = "Text", notifications = "Notifications", shortcuts = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .newChats: "plus.bubble"
            case .text: "textformat.size"
            case .notifications: "bell"
            case .shortcuts: "keyboard"
            }
        }
        var summary: String {
            switch self {
            case .appearance: "Kore's colours, from any Ghostty theme. The terminal follows."
            case .newChats: "What a new chat starts with. A reopened chat keeps its own."
            case .text: "Chat style and text size."
            case .notifications: "Sounds and the Dock while Kore is in the background."
            case .shortcuts: "Every menu shortcut, and how to change one."
            }
        }
    }

    @State private var section: Section? = ProcessInfo.processInfo.environment["KORE_SETTINGS"].flatMap { name in
        Section.allCases.first { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }
    } ?? .appearance

    var body: some View {
        let appearance = Appearance.shared
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(Size.Settings.sidebar)
            // Under the sections: every setting back to Kore's own, after a warning.
            .safeAreaInset(edge: .bottom) { RestoreDefaultsButton().padding(Space.lg) }
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        let current = section ?? .appearance
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(current.rawValue).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(current.summary).font(Chrome.body).foregroundStyle(Theme.secondary)
                        }
                        page(current)
                    }
                    .padding(Space.xxxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SaveBar(appearance: appearance)
            }
            .background(Theme.background)
        }
        .frame(width: Size.Settings.width, height: Size.Settings.height)
        .modifier(ThemeScheme())
        // Closed without Save: the theme goes back to the kept one.
        .onDisappear { appearance.revert() }
    }

    @ViewBuilder private func page(_ section: Section) -> some View {
        switch section {
        case .appearance: ThemeSettings()
        case .newChats: NewChatSettings()
        case .text: TextSettings()
        case .notifications: AlertSettings()
        case .shortcuts: ShortcutSettings()
        }
    }
}

// MARK: - Layout parts (ghostty-config's rows: name and note on the left, control on the right)

private struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let title { Text(title).font(Chrome.captionMedium).foregroundStyle(Theme.secondary).textCase(.uppercase) }
            VStack(spacing: 0) { content }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        }
    }
}

private struct Row<Control: View>: View {
    let title: String
    var note: String? = nil
    var last = false
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(Chrome.body).foregroundStyle(Theme.text)
                    if let note { Text(note).font(Chrome.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: Space.xl)
                control.frame(maxWidth: Size.Settings.control, alignment: .trailing)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            if !last { Theme.border.frame(height: Stroke.hairline).padding(.leading, Space.xl) }
        }
    }
}

/// Save keeps the previewed theme; Revert goes back. Everything else keeps as it's changed.
private struct SaveBar: View {
    let appearance: Appearance

    var body: some View {
        HStack(spacing: Space.md) {

            Image(systemName: appearance.unsaved ? "circle.fill" : "checkmark.circle")
                .font(Chrome.caption)
                .foregroundStyle(appearance.unsaved ? Theme.accent : Theme.secondary)
            Text(appearance.unsaved ? "Previewing \(appearance.name): not saved" : "All changes saved")
                .font(Chrome.label).foregroundStyle(Theme.secondary)
            Spacer()
            Button("Revert") { appearance.revert() }.disabled(!appearance.unsaved)
            Button("Save") { appearance.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!appearance.unsaved)
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.vertical, Space.lg)
        .background(Theme.surface)
        .overlay(alignment: .top) { Theme.border.frame(height: Stroke.hairline) }
    }
}

// MARK: - Appearance

/// Every theme as a card in its own colours, as ghostty-config shows them; a click previews it
/// across Kore and the terminal.
private struct ThemeSettings: View {
    @State private var names = Appearance.names()
    @State private var search = ""

    private var shown: [String] {
        search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let appearance = Appearance.shared
        VStack(alignment: .leading, spacing: Space.xl) {
            Card(title: "Current") {
                Row(title: appearance.name, note: "Roles Kore draws with, from this theme.", last: true) {
                    RoleSwatches(palette: appearance.palette(appearance.name))
                }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Search \(names.count) themes", text: $search).textFieldStyle(.plain).font(Chrome.body)
            }
            .padding(.horizontal, Space.lg)
            .frame(height: Size.TabGroup.field)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
            if names.count == 1 {
                Text("No Ghostty themes found. Install Ghostty, or put theme files in ~/.config/ghostty/themes.")
                    .font(Chrome.label).foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Size.Settings.card), spacing: Space.lg)], spacing: Space.lg) {
                ForEach(shown, id: \.self) { name in
                    ThemeCard(name: name, picked: appearance.name == name) { appearance.preview(name) }
                }
            }
        }
    }
}

/// Background, text, secondary, hint, accent, danger: each a dot with its name.
private struct RoleSwatches: View {
    let palette: ThemePalette

    var body: some View {
        let roles: [(String, NSColor)] = [
            ("Ground", palette.background), ("Text", palette.text), ("Secondary", palette.secondary),
            ("Hint", palette.tertiary), ("Accent", palette.accent), ("Danger", palette.danger),
        ]
        HStack(spacing: Space.xs) {
            ForEach(roles, id: \.0) { role in
                Circle().fill(Theme.Settings.swatch(role.1))
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: Stroke.hairline))
                    .frame(width: Size.Settings.swatch, height: Size.Settings.swatch)
                    .help(role.0)
            }
        }
    }
}

private struct ThemeCard: View {
    let name: String
    let picked: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        let appearance = Appearance.shared
        let palette = appearance.palette(name)
        let ansi = appearance.theme(name)?.ansi
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                // A little terminal in the theme's own colours.
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text("❯").foregroundStyle(Theme.Settings.swatch(palette.accent))
                        Text("kore").foregroundStyle(Theme.Settings.swatch(palette.text))
                        Text("--theme").foregroundStyle(Theme.Settings.swatch(palette.secondary))
                    }
                    .font(.system(.caption, design: .monospaced))
                    HStack(spacing: Space.xxs) {
                        ForEach(0..<8, id: \.self) { i in
                            Circle().fill(Theme.Settings.swatch(ansi?[i] ?? (i == 1 ? palette.danger : i == 4 ? palette.accent : palette.secondary)))
                                .frame(width: Size.Settings.dot, height: Size.Settings.dot)
                        }
                    }
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, minHeight: Size.Settings.cardPreview, alignment: .leading)
                .background(Theme.Settings.swatch(palette.background))
                HStack {
                    Text(name).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if picked { Image(systemName: "checkmark").font(Chrome.caption).foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(hovered ? Theme.surfaceHover : Theme.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(picked ? Theme.accent : Theme.border, lineWidth: picked ? Stroke.emphasis : Stroke.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(name)
    }
}

// MARK: - New chats

private struct NewChatSettings: View {
    @AppStorage(KoreSettings.autoCompactKey) private var autoCompact = -1

    var body: some View {
        Card {
            Row(title: "Auto-compact", note: "Off or 90% keeps the vault's 85% checkpoint ahead of any compaction.", last: true) {
                Picker("", selection: $autoCompact) {
                    Text("Chat's own (Off)").tag(-1)
                    Text("Off").tag(0)
                    ForEach(ContextStore.snapPoints, id: \.self) { Text("At \($0)%").tag($0) }
                }
                .labelsHidden()
            }
        }
        .onChange(of: autoCompact) { _, value in
            if value < 0 { UserDefaults.standard.removeObject(forKey: KoreSettings.autoCompactKey) }
        }
        ForEach(Registry.all, id: \.id) { ProviderDefaults(provider: $0) }
    }
}

private struct ProviderDefaults: View {
    /// The picked model's levels; with none picked (or none known), every level its models have.
    static func levels(_ models: [(id: String, name: String, efforts: [String])], model: String) -> [String] {
        if let picked = models.first(where: { $0.id == model }), !picked.efforts.isEmpty { return picked.efforts }
        let all = EffortScale.levels(models.map { ModelOption(id: $0.id, name: $0.name, resolved: $0.id, efforts: $0.efforts) })
        return all.isEmpty ? ["low", "medium", "high", "xhigh", "max"] : all
    }

    let provider: ProviderDescriptor
    @AppStorage private var model: String
    @AppStorage private var effort: String
    @AppStorage private var mode: String

    init(provider: ProviderDescriptor) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", KoreSettings.modelKey(provider.id))
        _effort = AppStorage(wrappedValue: "", KoreSettings.effortKey(provider.id))
        _mode = AppStorage(wrappedValue: "", KoreSettings.modeKey(provider.id))
    }

    var body: some View {
        Card(title: provider.name) {
            let models = KoreSettings.knownModels(provider.id)
            Row(title: "Model", note: models.isEmpty ? "Start a \(provider.name) chat once to list its models." : nil) {
                Picker("", selection: $model) {
                    Text("CLI default").tag("")
                    ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                    // A pick from before that the CLI no longer lists stays shown.
                    if !model.isEmpty, !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
                }
                .labelsHidden()
            }
            Row(title: "Effort") {
                let levels = Self.levels(models, model: model)
                Picker("", selection: $effort) {
                    Text("CLI default").tag("")
                    ForEach(levels, id: \.self) { Text(EffortScale.name($0)).tag($0) }
                    if !effort.isEmpty, !levels.contains(effort) { Text(EffortScale.name(effort)).tag(effort) }
                }
                .labelsHidden()
            }
            Row(title: "Mode", last: true) {
                Picker("", selection: $mode) {
                    Text("Last used").tag("")
                    ForEach(provider.modes.filter { $0.id != "plan" }) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
            }
        }
    }
}

// MARK: - Text

private struct TextSettings: View {
    @AppStorage(ChatStyle.key) private var chatStyle = ChatStyle.classic

    var body: some View {
        let zoom = Zoom.shared
        Card(title: "Chat") {
            Row(title: "Chat style", note: "Document: tables and code in cards, quotes on a bar, more air between blocks, no timeline rail. Classic is Kore's original.", last: true) {
                Picker("", selection: $chatStyle) {
                    ForEach(ChatStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: chatStyle) { Appearance.shared.refresh() }
            }
        }
        Card(title: "Fonts") {
            Row(title: "Text size", note: "\(Int((zoom.scale * 100).rounded()))%. Same as ⌘= and ⌘-.", last: true) {
                Slider(
                    value: Binding(get: { Double(zoom.scale) }, set: { zoom.commitPinch(CGFloat(($0 * 10).rounded() / 10)) }),
                    in: Double(Zoom.range.lowerBound)...Double(Zoom.range.upperBound), step: 0.1)
            }
        }
    }
}

// MARK: - Notifications

private struct AlertSettings: View {
    var body: some View {
        AlertCard(alert: .finished, title: "A chat finishes")
        AlertCard(alert: .approval, title: "A chat needs approval")
    }
}

private struct AlertCard: View {
    let title: String
    @AppStorage private var sound: String
    @AppStorage private var bounce: Bool

    init(alert: KoreSettings.Alert, title: String) {
        self.title = title
        _sound = AppStorage(wrappedValue: "", alert.soundKey)
        _bounce = AppStorage(wrappedValue: false, alert.bounceKey)
    }

    var body: some View {
        Card(title: title) {
            Row(title: "Sound", note: "Only while Kore isn't the front app.") {
                Picker("", selection: $sound) {
                    Text("None").tag("")
                    ForEach(KoreSettings.sounds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: sound) { _, name in if !name.isEmpty { NSSound(named: name)?.play() } }
            }
            Row(title: "Bounce the Dock icon", last: true) {
                Toggle("", isOn: $bounce).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Shortcuts

/// Every menu shortcut, read from the menu bar as it is. macOS rebinds a menu item per app
/// (Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts), so Kore needn't.
private struct ShortcutSettings: View {
    private struct Item: Identifiable {
        let id = UUID()
        let menu: String
        let title: String
        let keys: String
    }

    @State private var items: [Item] = []

    var body: some View {
        Card {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Row(title: item.title, note: item.menu, last: index == items.count - 1) {
                    Text(item.keys).font(Chrome.labelDigits).foregroundStyle(Theme.secondary)
                }
            }
        }
        .onAppear { items = Self.read(NSApp.mainMenu) }
        Card(title: "Change one") {
            Row(title: "App Shortcuts", note: "Add Kore with the menu item's exact name and the keys you want.", last: true) {
                Button("Open Keyboard Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private static func read(_ menu: NSMenu?, under path: String = "") -> [Item] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [Item] in
            if let sub = item.submenu { return read(sub, under: path.isEmpty ? item.title : path) }
            guard !item.keyEquivalent.isEmpty, !item.title.isEmpty else { return [] }
            return [Item(menu: path, title: item.title, keys: keys(item))]
        }
    }

    private static func keys(_ item: NSMenuItem) -> String {
        let m = item.keyEquivalentModifierMask
        var text = ""
        if m.contains(.control) { text += "⌃" }
        if m.contains(.option) { text += "⌥" }
        if m.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if m.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "⎋", "\u{7f}": "⌫"]
        return text + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }
}

// MARK: - Opening Settings

/// App menu ▸ Settings… (⌥⌘,; ⌘, stays the / menu's Account).
struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsView.id) }
            .keyboardShortcut(",", modifiers: [.command, .option])
    }
}

/// The title row's cog: opens Settings.
struct SettingsButton: View {
    let size: CGFloat
    @Environment(\.openWindow) private var openWindow
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button {
            openWindow(id: SettingsView.id)
        } label: {
            Image(systemName: "gearshape")
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Settings (⌥⌘,)")
        .accessibilityLabel(Text("Settings"))
    }
}

/// The sidebar's foot: Restore Defaults, behind a warning that says what goes and what stays.
private struct RestoreDefaultsButton: View {
    @State private var asking = false

    var body: some View {
        Button {
            asking = true
        } label: {
            Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                .font(Chrome.label)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .alert("Restore all settings to their defaults?", isPresented: $asking) {
            Button("Restore Defaults", role: .destructive) { KoreSettings.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Theme, new-chat defaults, chat style, text size and notifications go back to Kore's own. This can't be undone.")
        }
    }
}
