import AppKit
import KoreCore
import SwiftUI
import UniformTypeIdentifiers

/// A cloud platform's form, in the whole Account card (account-popup.html §7.3): the platform's
/// name, two to five rows (a label column, then a field, picker or file), and a footer saying
/// where Save puts it, with Save and Cancel. A picker's choices unfold under it in the card. The secrets are this view's alone: cleared as Save
/// sends them, and gone when the form closes. Every other value is `AccountState.form`'s.
struct PlatformFormView: View {
    let state: AccountState
    let platform: ClaudeSettings.Platform
    @StateObject private var bedrockKey = Local("")
    @StateObject private var accessSecret = Local("")
    @StateObject private var accessToken = Local("")
    @StateObject private var foundryKey = Local("")
    @StateObject private var window = Held<NSWindow?>(nil)
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case apiKey, keyID, secret, token, region, project, vertexRegion, resource, foundryKey
    }

    private var secrets: PlatformForm.Secrets {
        PlatformForm.Secrets(
            bedrockKey: bedrockKey.value, accessSecret: accessSecret.value, accessToken: accessToken.value, foundryKey: foundryKey.value)
    }

    private var form: PlatformForm { state.form }
    private var canSave: Bool { !state.saving && state.setup(platform, secrets) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(platform.name)
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(minHeight: Size.MessageActions.button)
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 0) {
                rows
            }
            .padding(.top, Space.xs)
            footer.padding(.top, Space.sm)
        }
        .background(WindowReader { window.value = $0 })
        .onAppear { focusFirstEmpty() }
        .onChange(of: form.bedrock) { focusFirstEmpty() }
        .onChange(of: form.vertex) { focusFirstEmpty() }
    }

    // MARK: Rows

    @ViewBuilder private var rows: some View {
        switch platform {
        case .bedrock:
            let credentials = ClaudeSettings.BedrockCredentials.allCases.map { choice in
                Choice(choice.rawValue, PlatformForm.label(choice), choice == form.bedrock) { state.form.bedrock = choice }
            }
            row("Credentials") { picker("credentials", PlatformForm.short(form.bedrock)) }
            choices("credentials", credentials)
            switch form.bedrock {
            case .profile:
                row("Profile") {
                    if form.profiles.names.isEmpty {
                        Text("None in ~/.aws/config").font(TextStyle.label).foregroundStyle(Theme.tertiary).fieldWell(focused: false, fills: false)
                    } else {
                        picker("profile", form.profile ?? "")
                    }
                }
                choices("profile", form.profiles.names.map { name in Choice(name, name, name == form.profile) { state.form.pick(profile: name) } })
            case .apiKey:
                row("API key") { secret(.apiKey, "apikey", bedrockKey, prompt: "Bedrock API key", saved: .bedrockKey) }
            case .accessKey:
                row("Key ID") { text(.keyID, "keyid", binding(\.accessKeyID), prompt: "AKIA…") }
                row("Secret") { secret(.secret, "secret", accessSecret, prompt: "Secret access key", saved: .accessSecret) }
                row("Token") { secret(.token, "token", accessToken, prompt: "Optional", saved: nil) }
            case .environment:
                EmptyView()
            }
            row("Region") {
                text(.region, "region", edited(\.region, flag: \.regionEdited), prompt: "us-east-1")
            }
        case .vertex:
            let credentials = ClaudeSettings.VertexCredentials.allCases.map { choice in
                Choice(choice.rawValue, PlatformForm.label(choice), choice == form.vertex) { state.form.vertex = choice }
            }
            row("Credentials") { picker("credentials", PlatformForm.short(form.vertex)) }
            choices("credentials", credentials)
            if form.vertex == .keyFile {
                row("Key file") { keyFile }
            }
            row("Project") {
                text(.project, "project", edited(\.project, flag: \.projectEdited), prompt: "my-gcp-project")
            }
            row("Region") { text(.vertexRegion, "region", binding(\.vertexRegion), prompt: "us-east5") }
        case .foundry:
            row("Resource") { text(.resource, "resource", binding(\.resource), prompt: "my-resource") }
            row("API key") { secret(.foundryKey, "foundrykey", foundryKey, prompt: "Optional", saved: .foundryKey) }
        }
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow {
            Text(label).font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
            HStack(spacing: Space.sm) { content() }
                .frame(maxWidth: .infinity, minHeight: Size.usageResetRow, maxHeight: Size.usageResetRow, alignment: .leading)
        }
    }

    private func binding(_ path: WritableKeyPath<PlatformForm, String>) -> Binding<String> {
        Binding(
            get: { state.form[keyPath: path] },
            set: {
                // A field hands its text back as focus moves: only a change is an edit.
                guard $0 != state.form[keyPath: path] else { return }
                state.form[keyPath: path] = $0
                state.editedForm()
            })
    }

    /// A field that stops following its default (the profile's region, the key file's
    /// project) once it's typed in.
    private func edited(_ path: WritableKeyPath<PlatformForm, String>, flag: WritableKeyPath<PlatformForm, Bool>) -> Binding<String> {
        Binding(
            get: { state.form[keyPath: path] },
            set: {
                guard $0 != state.form[keyPath: path] else { return }
                state.form[keyPath: path] = $0
                state.form[keyPath: flag] = true
                state.editedForm()
            })
    }

    private func text(_ field: Field, _ name: String, _ value: Binding<String>, prompt: String) -> some View {
        TextField("", text: value, prompt: Text(prompt).foregroundStyle(Theme.tertiary))
            .focused($focus, equals: field)
            .fieldWell(focused: focus == field)
            .onSubmit(save)
            .storyID(StoryID.Composer.accountField(name))
    }

    /// A masked field. With the secret already saved, it reads "Unchanged", and left empty it
    /// keeps it.
    private func secret(_ field: Field, _ name: String, _ value: Local<String>, prompt: String, saved: PlatformForm.Secret?) -> some View {
        let kept = saved.map { form.savedSecrets.contains($0.rawValue) } ?? false
        return SecureField("", text: Binding(get: { value.value }, set: { new in
            value.value = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.value.isEmpty { state.filled.remove(name) } else { state.filled.insert(name) }
            state.editedForm()
        }), prompt: Text(kept ? "Unchanged" : prompt).foregroundStyle(Theme.tertiary))
            .focused($focus, equals: field)
            .fieldWell(focused: focus == field)
            .onSubmit(save)
            .storyID(StoryID.Composer.accountField(name))
    }

    /// The short choice and a ⌄ (⌃ while its choices show under it).
    private func picker(_ name: String, _ choice: String) -> some View {
        let open = state.formPicker == name
        return Button {
            state.toggleFormPicker(name)
        } label: {
            HStack(spacing: Space.xs) {
                Text(choice).foregroundStyle(Theme.text)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(Glyph.chevron).foregroundStyle(Theme.secondary)
            }
            .fieldWell(focused: open, fills: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .storyID(name == "credentials" ? StoryID.Composer.account.part(.credentials) : StoryID.Composer.accountField(name))
    }

    /// A picker's choices, unfolded under its row: the CLI's full labels, the current one checked,
    /// in the methods' rows.
    @ViewBuilder private func choices(_ name: String, _ choices: [Choice]) -> some View {
        if state.formPicker == name {
            GridRow {
                // The whole card's width, so the CLI's full labels fit.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices, id: \.id) { choice in
                        ChoiceRow(choice: choice) {
                            choice.pick()
                            state.editedForm()
                            state.foldFormPicker()
                        }
                        .storyID(StoryID.Composer.accountChoice(name, choice.id))
                    }
                }
                .gridCellColumns(2)
            }
        }
    }

    /// The key file's name (its path on hover), or "No file", then Choose….
    @ViewBuilder private var keyFile: some View {
        if let path = form.keyFile {
            Text(URL(fileURLWithPath: path).lastPathComponent).font(TextStyle.label).foregroundStyle(Theme.text).lineLimit(1)
                .truncationMode(.middle).help(path)
        } else {
            Text("No file").font(TextStyle.label).foregroundStyle(Theme.tertiary)
        }
        Spacer(minLength: 0)
        Button("Choose…", action: choose)
            .smallButton()
            .storyID(StoryID.Composer.account.part(.choose))
    }

    /// An open panel for the key file, as a sheet on the window (the popup's monitor leaves the
    /// sheet's clicks alone). A storyline host is asked instead.
    private func choose() {
        if StoryHost.installed {
            if let url = StorylineSeams.chooseFile?() { pick(url) }
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { pick(url) }
        }
        if let window = window.value { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func pick(_ url: URL) {
        state.form.pick(keyFile: url)
        state.editedForm()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            if state.saving {
                HStack(spacing: Space.xs) {
                    SpinningArc().frame(width: Size.spinner, height: Size.spinner)
                    Text(AccountText.saving).font(TextStyle.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            } else {
                let error = state.formError
                let words = error ?? form.caption(platform, keyTyped: !foundryKey.value.isEmpty)
                // A key kept in plain text is a fact to read before Save, not a hint.
                let plain = error == nil && words == AccountText.savedPlainSecret
                HStack(spacing: Space.xs) {
                    if plain {
                        Image(systemName: "exclamationmark.triangle").font(TextStyle.caption).foregroundStyle(Theme.warning)
                    }
                    Text(words)
                        .font(TextStyle.caption)
                        .foregroundStyle(error != nil ? Theme.danger : plain ? Theme.secondary : Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(words)
                Spacer(minLength: 0)
                Button("Save", action: save)
                    .smallButton(prominent: true)
                    .disabled(!canSave)
                    .storyID(StoryID.Composer.account.part(.save))
                Button("Cancel") { state.closeEditor() }
                    .smallButton()
                    .storyID(StoryID.Composer.account.part(.cancel))
            }
        }
        .frame(minHeight: Size.usageResetRow, maxHeight: Size.usageResetRow)
    }

    /// Return and Save: the secrets go once, and are cleared at once.
    private func save() {
        guard canSave else { return }
        let sent = secrets
        for secret in [bedrockKey, accessSecret, accessToken, foundryKey] { secret.value = "" }
        state.save(platform, sent)
    }

    /// The first field with nothing in it takes the keys.
    private func focusFirstEmpty() {
        let order: [(Field, Bool)]
        switch platform {
        case .bedrock:
            switch form.bedrock {
            case .profile, .environment: order = [(.region, form.region.isEmpty)]
            case .apiKey: order = [(.apiKey, bedrockKey.value.isEmpty), (.region, form.region.isEmpty)]
            case .accessKey:
                order = [(.keyID, form.accessKeyID.isEmpty), (.secret, accessSecret.value.isEmpty), (.region, form.region.isEmpty)]
            }
        case .vertex: order = [(.project, form.project.isEmpty), (.vertexRegion, form.vertexRegion.isEmpty)]
        case .foundry: order = [(.resource, form.resource.isEmpty), (.foundryKey, foundryKey.value.isEmpty)]
        }
        focus = order.first(where: \.1)?.0 ?? order.first?.0
    }
}

/// One of a form picker's choices: its id (the case's name, a profile's), its label, whether it's
/// the current one, and what picking it sets.
private struct Choice {
    let id: String
    let label: String
    let current: Bool
    let pick: () -> Void

    init(_ id: String, _ label: String, _ current: Bool, pick: @escaping () -> Void) {
        (self.id, self.label, self.current, self.pick) = (id, label, current, pick)
    }
}

/// A choice's row, as tall as a sign-in method's; the current one checked.
private struct ChoiceRow: View {
    let choice: Choice
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Text(choice.label).font(TextStyle.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Space.md)
                if choice.current {
                    Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.method, alignment: .leading)
            .hoverFill(hovered.value, Theme.Row.hover(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityAddTraits(choice.current ? .isSelected : [])
    }
}
