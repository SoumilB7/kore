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
    /// The ⌄'s methods are unfolded in the card, and the groups disclosed in them, by title.
    private(set) var methodsOpen = false
    private(set) var disclosed: Set<String> = []
    private(set) var editor: Editor?
    /// A form's picker unfolded in the card, by name ("credentials", "profile").
    private(set) var formPicker: String?
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
        (askingSignOut, copied, methodsOpen, editor, formPicker, formError, filled) = (false, false, false, nil, nil, nil, [])
        store.dismissOutcome(provider)
        if store.flow(provider)?.step.live != true { Task { await store.refresh(provider) } }
    }

    /// Closing never stops a sign-in; an outcome goes, and the next open shows rest. A field or
    /// form goes, its secrets with it.
    func close() {
        guard isOpen else { return }
        isOpen = false
        (askingSignOut, methodsOpen, editor, formPicker, formError, filled) = (false, false, nil, nil, nil, [])
        store.dismissOutcome(provider)
    }

    /// Esc: the methods or a form's choices fold, then the field or form, then the question go
    /// first. False when there's nothing to step back from, and the popup closes.
    func stepBack() -> Bool {
        if formPicker != nil {
            formPicker = nil
            return true
        }
        if methodsOpen {
            methodsOpen = false
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

    /// Sign in, Switch account (Add account), Try again: the current method, or the one picked.
    /// Signed in where the CLI keeps several logins, it adds one. A key or a platform opens its
    /// field or form, filled in with what's saved (Claude's settings, one for every login).
    func signIn(_ method: SignInMethod? = nil) {
        askingSignOut = false
        methodsOpen = false
        guard let method = method ?? store.currentMethod(provider) else { return }
        if method.opensEditor { return openEditor(method) }
        closeEditor()
        if addsLogins {
            store.addLogin(provider, method: method, in: folder)
        } else {
            store.signIn(provider, method: method, in: folder)
        }
    }

    /// Signed in, with logins Kore can keep side by side: the row's sign-in adds one.
    var addsLogins: Bool {
        guard case .signedIn = store.status(provider) else { return false }
        return !store.logins(provider).isEmpty
    }

    func switchLogin(_ id: String?) { store.switchLogin(provider, to: id) }

    func removeLogin(_ id: String) { store.removeLogin(provider, id) }

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
        (editor, formPicker, formError, filled) = (nil, nil, nil, [])
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

    /// A form's picker: its choices unfold under it in the card, or fold.
    func toggleFormPicker(_ name: String) { formPicker = formPicker == name ? nil : name }

    /// A choice picked: the choices fold.
    func foldFormPicker() { formPicker = nil }

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

    /// The ⌄'s methods: those the CLI's policy lists, in their groups, the current one checked.
    var menuItems: [MethodMenuItem] { store.menu(provider) }

    /// More than one method to pick from: the ⌄ shows.
    var hasMenu: Bool { store.methods(provider).count > 1 }

    /// The ⌄: the methods unfold above the account, every group closed; again, they fold.
    func toggleMethods() {
        askingSignOut = false
        (methodsOpen, disclosed) = (!methodsOpen, [])
    }

    /// A group's row: its methods show under it, or go.
    func toggleGroup(_ title: String) {
        if disclosed.contains(title) { disclosed.remove(title) } else { disclosed.insert(title) }
    }

    /// The methods while they're unfolded.
    var methodsShown: [MethodMenuItem]? { methodsOpen ? menuItems : nil }

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
            chat: chat, id: StoryID.Composer.account, isOpen: { state.isOpen }, stepBack: { state.stepBack() }, close: { state.close() },
            editing: { state.isEditing }
        ) {
            if case .platform(let platform) = state.editor {
                PlatformFormView(state: state, platform: platform)
                    .transition(.opacity.animation(Motion.fade))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // The ⌄'s methods, unfolded above the account (model-picker.html, "Account ⌄").
                    if let items = state.methodsShown {
                        MethodList(state: state, items: items)
                        Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
                    }
                    content
                }
                .transition(.opacity.animation(Motion.fade))
            }
        }
    }

    @ViewBuilder private var content: some View {
        let provider = chat.provider.id
        switch store.status(provider) {
        case .signedIn(let identity) where store.logins(provider).count > 1:
            loginList(identity)
        case .unknown where store.logins(provider).count > 1:
            // Just switched: the list stays, the new login's caption to come.
            loginList(nil)
        case .signedIn(let identity):
            VStack(alignment: .leading, spacing: 0) {
                header(AccountText.header(identity))
                // Asked to sign out, the line under the header says what it reaches: the card
                // keeps its height, so the row (and No, go back over Sign out) stays put.
                let reach = state.askingSignOut ? signOutReach : nil
                let caption = reach ?? AccountText.caption(identity)
                Text(caption)
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.secondary)
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

    /// With more than main: the logins in the header's place, then the row.
    private func loginList(_ identity: AccountIdentity?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LoginList(state: state, provider: chat.provider.id, identity: identity)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
            row(signedIn: true)
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
            // Signed in, it's in the header's caption line instead (the list has none).
            return signedIn && store.logins(provider).count < 2 ? nil : (signOutReach, false)
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
                    .smallButton(prominent: true)
                    .storyID(id.part(.allow))
                    .tabStop(id.part(.allow)) { state.signOut() }
                // Asked from the keys, the ring lands here: a second Return goes back.
                Button("No, go back") { state.cancelSignOut() }
                    .smallButton()
                    .storyID(id.part(.cancel))
                    .tabStop(id.part(.cancel), after: id.part(.signOut)) { state.cancelSignOut() }
            } else if state.showsKeyField {
                KeyField(state: state, provider: provider)
            } else if let step = flow?.step {
                flowLine(step, id: id)
            } else if signedIn {
                Spacer(minLength: 0)
                // Apart enough that each one's clicks stay its own.
                HStack(spacing: Space.sm) {
                    Button(state.addsLogins ? "Add account" : "Switch account") { state.signIn() }
                        .smallButton()
                        .storyID(id.part(.switch))
                        .tabStop(id.part(.switch)) { state.signIn() }
                    if state.hasMenu { MethodMenuButton(state: state).storyID(id.part(.method)) }
                }
                Button("Sign out") { state.askSignOut() }
                    .smallButton()
                    .storyID(id.part(.signOut))
                    .tabStop(id.part(.signOut), after: id.part(.cancel)) { state.askSignOut() }
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
        .hoverFill(state.askingSignOut, Theme.Row.selected(.surface))
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
                .smallButton()
                .storyID(id.part(.copy))
                .tabStop(id.part(.copy)) { state.copy(url.absoluteString) }
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
                .smallButton()
                .storyID(id.part(.copy))
                .tabStop(id.part(.copy)) { state.copy(code) }
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
            .smallButton()
            .storyID(id.part(.cancel))
            .tabStop(id.part(.cancel)) { state.cancel() }
    }

    /// Sign in (or Try again) and, with more than one method, the ⌄ of methods.
    private func signInControl(_ title: String, id: StoryID) -> some View {
        HStack(spacing: Space.sm) {
            Button(title) { state.signIn() }
                .smallButton(prominent: true)
                .storyID(id.part(.signIn))
                .tabStop(id.part(.signIn)) { state.signIn() }
            if state.hasMenu { MethodMenuButton(state: state).storyID(id.part(.method)) }
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
            .smallButton(prominent: true)
            .disabled(key.value.isEmpty)
            .storyID(id.part(.signIn))
        Button("Cancel") {
            key.value = ""
            state.closeEditor()
        }
        .smallButton()
        .storyID(id.part(.cancel))
    }

    private func submit() {
        let sent = key.value
        guard !sent.isEmpty else { return }
        key.value = ""
        state.submitKey(sent)
    }
}

/// The ⌄: unfolds the CLI's sign-in methods in the card, and folds them again.
private struct MethodMenuButton: View {
    let state: AccountState

    var body: some View {
        IconButton(
            symbol: "chevron.down", kind: .mini, font: Glyph.chevron, isOn: state.methodsOpen, help: "Sign-in method"
        ) { state.toggleMethods() }
            .tabStop(StoryID.Composer.account.part(.method)) { state.toggleMethods() }
    }
}

/// The CLI's sign-in methods, in the card: a 36pt row each with the CLI's hint under its title,
/// the current one checked; a group discloses its methods under it, indented, never a submenu.
private struct MethodList: View {
    let state: AccountState
    let items: [MethodMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let open = state.disclosed.contains(item.title)
                let press: @MainActor @Sendable () -> Void = { if let method = item.method { state.signIn(method) } else { state.toggleGroup(item.title) } }
                MethodRow(item: item, depth: 0, open: open, action: press)
                    .storyID(StoryID.Composer.accountMethod(item.title))
                    .tabStop(StoryID.Composer.accountMethod(item.title), action: press)
                if item.method == nil, open {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        let path = item.title + "/" + child.title
                        let press: @MainActor @Sendable () -> Void = { if let method = child.method { state.signIn(method) } }
                        MethodRow(item: child, depth: 1, open: false, action: press)
                            .storyID(StoryID.Composer.accountMethod(path))
                            .tabStop(StoryID.Composer.accountMethod(path), action: press)
                    }
                }
            }
        }
    }
}

/// One method, or a group (⌄ open, › closed); the hover fill under the pointer.
private struct MethodRow: View {
    let item: MethodMenuItem
    let depth: Int
    let open: Bool
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(TextStyle.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    if let hint = item.hint {
                        Text(hint).font(TextStyle.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: Space.md)
                if item.method == nil {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(Glyph.chevron).foregroundStyle(Theme.secondary)
                } else if item.checked {
                    Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, Space.lg + CGFloat(depth) * Size.Picker.indent)
            .padding(.trailing, Space.lg)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.method, alignment: .leading)
            .hoverFill(hovered.value, Theme.Row.hover(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityAddTraits(item.checked && item.method != nil ? .isSelected : [])
    }
}

/// With more than main, the CLI's logins in place of the header: a row each, the active one's
/// caption its plan and method and a ✓, main's "Main". A row switches to its login; an added
/// one's × (on hover) removes it.
private struct LoginList: View {
    let state: AccountState
    let provider: String
    let identity: AccountIdentity?
    private var store: AccountStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.logins(provider)) { login in
                LoginRow(state: state, login: login, caption: caption(login), reading: login.active && identity == nil)
            }
        }
        .padding(.horizontal, -Space.sm)
    }

    private func caption(_ login: AccountStore.Login) -> String? {
        let main = login.id == nil ? "Main" : nil
        guard login.active else { return main }
        return [main, identity.map(AccountText.caption)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct LoginRow: View {
    let state: AccountState
    let login: AccountStore.Login
    let caption: String?
    /// Its account being read, just switched to: the spinner in the ✓'s place.
    let reading: Bool
    @StateObject private var hovered = Local(false)

    var body: some View {
        let id = StoryID.Composer.accountLogin(login.id ?? "main")
        let title = login.email ?? (login.id == nil ? "Main account" : "Account")
        Button { if !login.active { state.switchLogin(login.id) } } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(login.active ? TextStyle.title : TextStyle.body)
                        .foregroundStyle(login.active ? Theme.text : Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(title)
                    if let caption {
                        Text(caption).font(TextStyle.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: Space.md)
                if reading {
                    SpinningArc().frame(width: Size.spinner, height: Size.spinner)
                } else if login.active {
                    Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
                } else if let added = login.id, hovered.value {
                    IconButton(symbol: "xmark", kind: .mini, font: Glyph.chevron, help: "Remove account") { state.removeLogin(added) }
                        .storyID(id.part(.cancel))
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.method, alignment: .leading)
            .hoverFill(hovered.value && !login.active, Theme.Row.hover(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .storyID(id)
        .tabStop(id) { state.switchLogin(login.id) }
        .accessibilityAddTraits(login.active ? .isSelected : [])
    }
}
