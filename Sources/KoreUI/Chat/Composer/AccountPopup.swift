import AppKit
import KoreCore
import Observation
import SwiftUI

/// The Account popup's state in one chat: open or not, the Sign out question, and the field or
/// form open in it. The account and any sign-in under way are the app's (`AccountStore`), shared
/// by every chat of the CLI. A typed secret is never here: it lives in its field's view, and only
/// whether a field holds one is (`filled`).
@MainActor @Observable
final class AccountState {
    /// A field or form open in the popup.
    enum Editor: Equatable {
        /// The key field, in the action row.
        case key
        /// A platform's form, in the whole card.
        case platform(ClaudeSettings.Platform)
    }

    private(set) var isOpen = false
    /// Sign out asked; the row is the question until it's answered.
    private(set) var askingSignOut = false
    /// Copy link (or code) was just pressed: it reads "Copied" for a moment.
    private(set) var copied = false
    /// The ⌄ menu is open for a storyline host: under a host the native menu never pops up (its
    /// tracking loop would hold the run), and an item is picked by its path.
    private(set) var hostMenuOpen = false
    private(set) var editor: Editor?
    /// The platform forms' values that aren't secret, kept for this run of Kore.
    var form = PlatformForm()
    /// A form's Save under way.
    private(set) var saving = false
    /// Why a form couldn't save; editing anything takes it away.
    private(set) var formError: String?
    /// The secret fields that hold text now, by name ("key", "apikey"…), for the lines.
    var filled: Set<String> = []
    @ObservationIgnored private(set) var provider = ""
    @ObservationIgnored private(set) var folder = FileManager.default.homeDirectoryForCurrentUser
    /// When Sign out asked (system uptime): a "Yes" within a double-click of it is the Sign out
    /// click's second half, and is ignored.
    @ObservationIgnored private var askedAt: TimeInterval = 0
    @ObservationIgnored private var copiedTimer: Task<Void, Never>?

    private var store: AccountStore { .shared }

    /// Opens on what the store has, and reads the account again behind it.
    func open(provider: String, folder: URL) {
        self.provider = provider
        self.folder = folder
        isOpen = true
        (askingSignOut, copied, hostMenuOpen, editor, formError, filled) = (false, false, false, nil, nil, [])
        store.dismissOutcome(provider)
        if store.flow(provider)?.step.live != true { Task { await store.refresh(provider) } }
    }

    /// Closing never stops a sign-in; an outcome goes, and the next open shows rest. A field or
    /// form goes, its secrets with it.
    func close() {
        guard isOpen else { return }
        isOpen = false
        (askingSignOut, hostMenuOpen, editor, formError, filled) = (false, false, nil, nil, [])
        store.dismissOutcome(provider)
    }

    /// Esc: the menu, then the field or form, then the question go first. False when there's
    /// nothing to step back from, and the popup closes.
    func stepBack() -> Bool {
        if hostMenuOpen {
            hostMenuOpen = false
            return true
        }
        if editor != nil, !saving {
            closeEditor()
            return true
        }
        guard askingSignOut else { return false }
        askingSignOut = false
        return true
    }

    /// A field or form has the keys (`ComposerPopup`'s `editing`).
    var isEditing: Bool {
        switch editor {
        case .platform: true
        // Through its sending too: a refused key brings the field back with the keys.
        case .key: showsKeyField || store.flow(provider)?.step == .signingIn
        case nil: false
        }
    }

    /// The key field shows: open, and no sign-in with it under way or done.
    var showsKeyField: Bool {
        guard editor == .key else { return false }
        switch store.flow(provider)?.step {
        case nil, .keyFailed: return true
        default: return false
        }
    }

    func askSignOut() {
        askingSignOut = true
        askedAt = ProcessInfo.processInfo.systemUptime
    }

    func cancelSignOut() { askingSignOut = false }

    /// Whether "Yes, sign out" would go: a double-click's time has passed since it asked.
    var confirmable: Bool { ProcessInfo.processInfo.systemUptime - askedAt >= NSEvent.doubleClickInterval }

    func signOut() {
        guard askingSignOut, confirmable else { return }
        askingSignOut = false
        store.signOut(provider)
    }

    /// Sign in, Switch account, Try again: the current method, or the one picked. A key or a
    /// platform opens its field or form, filled in with what's saved.
    func signIn(_ method: SignInMethod? = nil) {
        askingSignOut = false
        hostMenuOpen = false
        guard let method = method ?? store.currentMethod(provider) else { return }
        if method.opensEditor { return openEditor(method) }
        closeEditor()
        store.signIn(provider, method: method, in: folder)
    }

    private func openEditor(_ method: SignInMethod) {
        guard store.flow(provider)?.step.live != true else { return }
        store.dismissOutcome(provider)
        (formError, filled) = (nil, [])
        switch method.mechanism {
        case .platform(let platform):
            form.seed(
                platform, settings: ClaudeSettingsStore.read(), environment: ProcessInfo.processInfo.environment,
                profiles: platform == .bedrock ? AWSProfiles.read() : form.profiles)
            editor = .platform(platform)
        default:
            editor = .key
        }
    }

    /// Back to what was there: secrets go with the view, a refused key's words with the flow.
    func closeEditor() {
        guard editor != nil else { return }
        (editor, formError, filled) = (nil, nil, [])
        if case .keyFailed = store.flow(provider)?.step { store.dismissOutcome(provider) }
    }

    /// The key, sent once; the field's view has already forgotten it.
    func submitKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        filled = []
        store.useKey(provider, key) { [weak self] landed in
            if landed, self?.editor == .key { self?.editor = nil }
        }
    }

    /// The key field was edited: a refusal's words give way to the caption.
    func editedKey(filled: Bool) {
        self.filled = filled ? ["key"] : []
        if filled, case .keyFailed = store.flow(provider)?.step { store.dismissOutcome(provider) }
    }

    /// A form's field was edited: an error gives way to the caption.
    func editedForm() { formError = nil }

    /// What Save would write, or nil while a required field is missing.
    func setup(_ platform: ClaudeSettings.Platform, _ secrets: PlatformForm.Secrets) -> ClaudeSettings.Setup? {
        form.setup(platform, secrets: secrets, saved: ClaudeSettingsStore.read().object("env"))
    }

    /// Save: Claude's settings written, the status read again, then the account with "Saved.".
    func save(_ platform: ClaudeSettings.Platform, _ secrets: PlatformForm.Secrets) {
        guard !saving, let setup = setup(platform, secrets) else { return }
        (saving, formError, filled) = (true, nil, [])
        store.save(provider, setup) { [weak self] reason in
            guard let self else { return }
            saving = false
            if let reason {
                formError = AccountText.saveFailed(reason)
            } else if editor == .platform(platform) {
                editor = nil
            }
        }
    }

    func cancel() { store.cancel(provider) }

    func copy(_ text: String) {
        store.copy(text)
        copied = true
        copiedTimer?.cancel()
        copiedTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// The ⌄ menu: the methods the CLI's policy lists, in their submenus, the current one checked.
    var menuItems: [MethodMenuItem] { store.menu(provider) }

    /// More than one method to pick from: the ⌄ shows.
    var hasMenu: Bool { store.methods(provider).count > 1 }

    func showHostMenu() { hostMenuOpen = true }

    /// The menu's items as the host sees them while it's open.
    var hostMenu: [MethodMenuItem]? { hostMenuOpen ? menuItems : nil }

    /// A host's pick from the menu, as a click on the item does: by its path
    /// ("3rd-party platform/Amazon Bedrock…"), or its title.
    func pickHostMenu(_ path: String) {
        guard let leaves = hostMenu.map(MethodMenuItem.paths),
            let method = (leaves.first { $0.path == path } ?? leaves.first { $0.item.title == path })?.item.method
        else { return }
        hostMenuOpen = false
        signIn(method)
    }

    /// The identity signed in now, when there is one.
    var identity: AccountIdentity? {
        if case .signedIn(let identity) = store.status(provider) { identity } else { nil }
    }

    /// What Sign out asks about: a platform Kore set up by its name, else the CLI.
    func signOutSubject(product: String) -> String {
        guard let identity, identity.isKoreSetting, identity.platform != nil else { return product }
        return AccountText.header(identity)
    }

    /// The popup's lines as they read, for a storyline's checks: the header, the caption, then
    /// the action row's words ("you@example.com", "Claude Max · Claude.ai", "Waiting for the
    /// browser…"). A form reads its title, its rows ("Region: us-east-1") and its footer. A
    /// secret reads "••••", never what it is.
    func lines(product: String) -> [String] {
        if case .platform(let platform) = editor {
            let typed = filled.contains(PlatformForm.Secret.foundryKey.rawValue)
            let footer = saving ? AccountText.saving : formError ?? form.caption(platform, keyTyped: typed)
            return [platform.name] + form.lines(platform, filled: filled) + [footer]
        }
        switch store.status(provider) {
        case .signedIn(let identity):
            let shows = identity.changeable || store.flow(provider) != nil || editor != nil
            let row: [String] = shows ? rowWords(product: product, signedIn: true) : [AccountText.cantChange]
            return [AccountText.header(identity), AccountText.caption(identity)] + row
        case .signedOut:
            return rowWords(product: product, signedIn: false)
        case .unknown:
            return []
        case .unreadable(let reason):
            return [AccountText.readFailed(product, reason)]
        }
    }

    private func rowWords(product: String, signedIn: Bool) -> [String] {
        if askingSignOut { return [AccountText.askSignOut(signOutSubject(product: product))] }
        if showsKeyField {
            let field = "API key: " + (filled.contains("key") ? "••••" : "")
            if case .keyFailed(let reason) = store.flow(provider)?.step { return [field, AccountText.signInFailed(reason)] }
            return [field]
        }
        guard let step = store.flow(provider)?.step else { return signedIn ? [] : [AccountText.signedOut(product)] }
        return [AccountRow.words(step)]
    }
}

/// The / menu's Account, in Usage's place and frame (account-popup.html §6, §7): this chat's
/// CLI only. Signed in, the email (or the platform), a caption and one row with Switch account ⌄
/// and Sign out at its trailing edge; signed out, one row, "Claude Code isn't signed in." with
/// Sign in ⌄. The action row is the only line that changes: it runs the sign-in, the key field,
/// the Sign out question and their outcomes. A platform's form takes the whole card. A login Kore
/// can't change has one tertiary line in place of the row.
struct AccountPopup: View {
    let chat: Chat
    let state: AccountState
    private var store: AccountStore { .shared }
    private var product: String { chat.provider.usage.product }

    var body: some View {
        ComposerPopup(
            chat: chat, id: StoryID.Composer.account, stepBack: { state.stepBack() }, close: { state.close() },
            editing: { state.isEditing }
        ) {
            if case .platform(let platform) = state.editor {
                PlatformFormView(state: state, platform: platform)
                    .transition(.opacity.animation(Motion.fade))
            } else {
                content.transition(.opacity.animation(Motion.fade))
            }
        }
        // Under a storyline host, the ⌄ menu's items drawn over the card, so a snapshot has them.
        .overlay(alignment: .topLeading) {
            if StoryHost.installed, let items = state.hostMenu {
                // Its bottom a gap above the card's top, its height its own.
                HostMenu(items: items)
                    .fixedSize()
                    .padding(.bottom, Space.xs)
                    .frame(height: 0, alignment: .bottomLeading)  // lint:allow a zero-height anchor, not a size
            }
        }
    }

    @ViewBuilder private var content: some View {
        let provider = chat.provider.id
        switch store.status(provider) {
        case .signedIn(let identity):
            VStack(alignment: .leading, spacing: 0) {
                header(AccountText.header(identity))
                // Asked to sign out, the line under the header says what it reaches: the card
                // keeps its height, so the row (and No, go back over Sign out) stays put.
                let reach = state.askingSignOut ? signOutReach : nil
                let caption = reach ?? AccountText.caption(identity)
                Text(caption)
                    .font(TextStyle.caption)
                    .foregroundStyle(reach == nil ? Theme.secondary : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(caption)
                if identity.changeable || store.flow(provider) != nil || state.editor != nil {
                    row(signedIn: true).padding(.top, Space.sm)
                } else {
                    Text(AccountText.cantChange)
                        .font(TextStyle.caption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(AccountText.cantChange)
                        .padding(.top, Space.sm)
                }
            }
        case .signedOut:
            row(signedIn: false)
        case .unknown:
            // The first read, with nothing kept: the three lines blank, the spinner in the header.
            VStack(alignment: .leading, spacing: 0) {
                header(" ")
                Text(" ").font(TextStyle.caption)
                Color.clear.frame(height: Size.usageResetRow).padding(.top, Space.sm)
            }
        case .unreadable(let reason):
            Text(AccountText.readFailed(product, reason))
                .font(TextStyle.label)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The email in the title style, truncated in the middle; the spinner while the first read
    /// is under way.
    private func header(_ title: String) -> some View {
        HStack(spacing: Space.md) {
            Text(title)
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Spacer(minLength: 0)
            if store.status(chat.provider.id) == .unknown, store.isReading(chat.provider.id) {
                SpinningArc().frame(width: Size.spinner, height: Size.spinner)
            }
        }
        .frame(minHeight: Size.MessageActions.button)
    }

    /// The action row, and its caption when it has one.
    @ViewBuilder private func row(signedIn: Bool) -> some View {
        let flow = store.flow(chat.provider.id)
        VStack(alignment: .leading, spacing: 0) {
            AccountRow(state: state, flow: flow, signedIn: signedIn, product: product, provider: chat.provider.id)
            if let caption = caption(flow, signedIn: signedIn) {
                Text(caption.words)
                    .font(TextStyle.caption)
                    .foregroundStyle(caption.danger ? Theme.danger : Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(caption.words)
                    .transition(.opacity.animation(Motion.fade))
            }
        }
    }

    /// What a sign-out reaches, and the chats it stops.
    private var signOutReach: String {
        AccountText.signOutCaption(working: store.workingChats(chat.provider.id), setting: state.identity?.isKoreSetting == true)
    }

    /// Under the question (signed out), what a sign-out reaches; under the key field, where the key goes (or
    /// why it was refused); under a hand-off, what to do in Terminal; under a switch under way,
    /// what it means for the open chats.
    private func caption(_ flow: AccountStore.Flow?, signedIn: Bool) -> (words: String, danger: Bool)? {
        let provider = chat.provider.id
        if state.askingSignOut {
            // Signed in, it's in the header's caption line instead.
            return signedIn ? nil : (signOutReach, false)
        }
        if state.showsKeyField {
            if case .keyFailed(let reason) = flow?.step { return (AccountText.signInFailed(reason), true) }
            return (AccountText.keyCaption(provider), false)
        }
        guard let flow else { return nil }
        if flow.step == .terminal { return (AccountText.terminalCaption(flow.method), false) }
        guard signedIn, flow.switching else { return nil }
        switch flow.step {
        case .starting, .browser, .code: return (AccountText.moving, false)
        default: return nil
        }
    }
}

/// The action row, 26 high: at rest, the CLI's buttons at its trailing edge, Sign out last; then
/// the question (No, go back where Sign out was), the key field, the flow and its outcome, each
/// fading in where the last was. Nothing in it moves.
private struct AccountRow: View {
    let state: AccountState
    let flow: AccountStore.Flow?
    let signedIn: Bool
    let product: String
    let provider: String

    /// The row's words for a step, as `AccountState.lines` reports them.
    static func words(_ step: AccountStore.Step) -> String {
        switch step {
        case .starting: AccountText.starting
        case .browser: AccountText.browser
        case .code(let code, _): "Enter \(code)"
        case .terminal: AccountText.terminal
        case .refreshing: AccountText.refreshing
        case .signingIn: AccountText.signingIn
        case .signingOut: AccountText.signingOut
        case .signedIn: AccountText.signedIn
        case .switched: AccountText.switched
        case .same: AccountText.same
        case .refreshed: AccountText.refreshed
        case .saved: AccountText.saved
        case .signedOutOf(let name): AccountText.signedOutOf(name)
        case .failed(let reason), .keyFailed(let reason): AccountText.signInFailed(reason)
        case .refreshFailed(let reason): AccountText.refreshFailed(reason)
        case .signOutFailed(let reason): AccountText.signOutFailed(reason)
        case .timedOut: AccountText.timedOut
        }
    }

    private var key: String {
        if state.askingSignOut { return "ask" }
        if state.showsKeyField { return "key" }
        guard let step = flow?.step else { return signedIn ? "in" : "out" }
        return Self.words(step)
    }

    var body: some View {
        let id = StoryID.Composer.account
        HStack(spacing: Space.md) {
            if state.askingSignOut {
                Text(AccountText.askSignOut(state.signOutSubject(product: product)))
                    .foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Yes, sign out") { state.signOut() }
                    .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                    .storyID(id.part(.allow))
                Button("No, go back") { state.cancelSignOut() }
                    .buttonStyle(SubtleButtonStyle(small: true))
                    .storyID(id.part(.cancel))
            } else if state.showsKeyField {
                KeyField(state: state, provider: provider)
            } else if let step = flow?.step {
                flowLine(step, id: id)
            } else if signedIn {
                Spacer(minLength: 0)
                HStack(spacing: Space.xxs) {
                    Button("Switch account") { state.signIn() }
                        .buttonStyle(SubtleButtonStyle(small: true))
                        .storyID(id.part(.switch))
                    if state.hasMenu { MethodMenuButton(state: state).storyID(id.part(.method), press: { state.showHostMenu() }) }
                }
                Button("Sign out") { state.askSignOut() }
                    .buttonStyle(SubtleButtonStyle(small: true))
                    .storyID(id.part(.signOut))
            } else {
                Text(AccountText.signedOut(product))
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                signInControl("Sign in", id: id)
            }
        }
        .font(TextStyle.label)
        .foregroundStyle(Theme.secondary)
        .id(key)
        .transition(.opacity.animation(Motion.fade))
        .padding(.horizontal, state.askingSignOut ? Space.sm : 0)
        .frame(maxWidth: .infinity, minHeight: Size.usageResetRow, maxHeight: Size.usageResetRow, alignment: .leading)
        .hoverFill(state.askingSignOut, Theme.surfaceHover)
        // The question's fill reaches past the text's edge, the text staying on it.
        .padding(.horizontal, state.askingSignOut ? -Space.sm : 0)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func flowLine(_ step: AccountStore.Step, id: StoryID) -> some View {
        switch step {
        case .starting, .terminal, .refreshing:
            spinning(Self.words(step))
            cancel(id)
        case .browser(let url):
            spinning(AccountText.browser)
            Button(state.copied ? "Copied" : "Copy link") { state.copy(url.absoluteString) }
                .buttonStyle(SubtleButtonStyle(small: true))
                .storyID(id.part(.copy))
            cancel(id)
        case .code(let code, _):
            HStack(spacing: Space.xs) {
                Text("Enter")
                Text(code).font(TextStyle.code).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            .lineLimit(1)
            .help(AccountText.deviceHelp)
            Spacer(minLength: 0)
            Button(state.copied ? "Copied" : "Copy code") { state.copy(code) }
                .buttonStyle(SubtleButtonStyle(small: true))
                .storyID(id.part(.copy))
            cancel(id)
        case .signingIn, .signingOut:
            spinning(Self.words(step))
        case .signedIn, .switched, .same, .refreshed, .saved, .signedOutOf:
            let words = Self.words(step)
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark").font(Glyph.chevron)
                Text(words).lineLimit(1).truncationMode(.tail)
            }
            .help(step == .same ? AccountText.sameHelp : words)
            Spacer(minLength: 0)
        case .failed, .keyFailed, .refreshFailed:
            let words = Self.words(step)
            Text(words).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).help(words)
            Spacer(minLength: 0)
            signInControl("Try again", id: id)
        case .signOutFailed:
            let words = Self.words(step)
            Text(words).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).help(words)
            Spacer(minLength: 0)
        case .timedOut:
            Text(AccountText.timedOut).lineLimit(1)
            Spacer(minLength: 0)
            signInControl("Try again", id: id)
        }
    }

    private func spinning(_ words: String) -> some View {
        HStack(spacing: Space.xs) {
            SpinningArc().frame(width: Size.spinner, height: Size.spinner)
            Text(words).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func cancel(_ id: StoryID) -> some View {
        Button("Cancel") { state.cancel() }
            .buttonStyle(SubtleButtonStyle(small: true))
            .storyID(id.part(.cancel))
    }

    /// Sign in (or Try again) and, with more than one method, the ⌄ of methods.
    private func signInControl(_ title: String, id: StoryID) -> some View {
        HStack(spacing: Space.xxs) {
            Button(title) { state.signIn() }
                .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                .storyID(id.part(.signIn))
            if state.hasMenu { MethodMenuButton(state: state).storyID(id.part(.method), press: { state.showHostMenu() }) }
        }
    }
}

/// The key field in the action row: one masked line, then Sign in (off while it's empty) and
/// Cancel. The key is this view's alone: cleared as it's sent, and gone when the field closes.
private struct KeyField: View {
    let state: AccountState
    let provider: String
    @StateObject private var key = Local("")
    @FocusState private var focused: Bool

    var body: some View {
        let id = StoryID.Composer.account
        SecureField("", text: $key.value, prompt: Text(AccountText.keyPrompt(provider)).foregroundStyle(Theme.tertiary))
            .focused($focused)
            .fieldWell(focused: focused)
            .storyID(StoryID.Composer.accountField("key"))
            .onSubmit(submit)
            .onChange(of: key.value) { _, new in
                // A paste comes in with its line break; the key never has one.
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != new { key.value = trimmed }
                state.editedKey(filled: !trimmed.isEmpty)
            }
            .onAppear { focused = true }
        Button("Sign in", action: submit)
            .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
            .disabled(key.value.isEmpty)
            .storyID(id.part(.signIn))
        Button("Cancel") {
            key.value = ""
            state.closeEditor()
        }
        .buttonStyle(SubtleButtonStyle(small: true))
        .storyID(id.part(.cancel))
    }

    private func submit() {
        let sent = key.value
        guard !sent.isEmpty else { return }
        key.value = ""
        state.submitKey(sent)
    }
}

/// The ⌄: a native menu of the CLI's sign-in methods under it, with the CLI's hints as
/// subtitles and its groups as submenus. Under a storyline host the items are handed over
/// instead, and drawn over the card so a snapshot shows them.
private struct MethodMenuButton: View {
    let state: AccountState
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)

    var body: some View {
        IconButton(symbol: "chevron.down", kind: .mini, font: Glyph.chevron, help: "Sign-in method") { show() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
            .background(WindowReader { window.value = $0 })
    }

    private func show() {
        if StoryHost.installed { return state.showHostMenu() }
        guard let content = window.value?.contentView else { return }
        let picker = MethodPicker(state: state)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in state.menuItems { add(item, to: menu, picker: picker) }
        let box = frame.value
        let point = NSPoint(x: box.minX, y: content.isFlipped ? box.maxY + Space.xs : content.bounds.height - box.maxY - Space.xs)
        // Runs until the menu closes; the picker lives as long.
        menu.popUp(positioning: nil, at: point, in: content)
        withExtendedLifetime(picker) {}
    }

    private func add(_ item: MethodMenuItem, to menu: NSMenu, picker: MethodPicker) {
        if item.separated { menu.addItem(.separator()) }
        let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        entry.subtitle = item.hint
        if let method = item.method {
            entry.action = #selector(MethodPicker.pick(_:))
            entry.target = picker
            entry.representedObject = method.id
            entry.state = item.checked ? .on : .off
        } else {
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            for child in item.children { add(child, to: submenu, picker: picker) }
            entry.submenu = submenu
        }
        menu.addItem(entry)
    }
}

/// The menu's items as a storyline host is handed them, drawn like the menu: a ✓, the title and
/// its hint, a ▸ on a submenu, whose items follow it, indented.
private struct HostMenu: View {
    let items: [MethodMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                entry(item, depth: 0)
                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in entry(child, depth: 1) }
            }
        }
        .padding(.vertical, Space.xs)
        .panel(.panel)
    }

    @ViewBuilder private func entry(_ item: MethodMenuItem, depth: Int) -> some View {
        if item.separated { Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs) }
        HStack(spacing: Space.xs) {
            Text(item.checked && item.method != nil ? "✓" : " ").frame(width: Space.lg)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).foregroundStyle(Theme.text)
                if let hint = item.hint { Text(hint).font(TextStyle.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: Space.xl)
            if item.method == nil { Text("▸").foregroundStyle(Theme.secondary) }
        }
        .font(TextStyle.label)
        .padding(.leading, depth == 0 ? Space.sm : Space.xxxl)
        .padding(.trailing, Space.md)
        .padding(.vertical, Space.xxs)
    }
}

/// The menu items' target.
@MainActor
private final class MethodPicker: NSObject {
    let state: AccountState

    init(state: AccountState) { self.state = state }

    @objc func pick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
            let method = AccountStore.shared.methods(state.provider).first(where: { $0.id == id })
        else { return }
        state.signIn(method)
    }
}
