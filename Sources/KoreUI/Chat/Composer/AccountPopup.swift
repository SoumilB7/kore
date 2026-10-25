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
        /// A browser login's pasted code or callback URL; text stays in the field's view.
        case login
        /// A platform's form, in the whole card.
        case platform(ClaudeSettings.Platform)
    }

    /// What unfolds above the account: the ⌄'s methods, Add account's, or a login's ⋯.
    enum Palette: Equatable {
        case methods
        case add
        /// A login's (nil: main's).
        case login(String?)
    }

    private(set) var isOpen = false
    /// Sign out asked; the row is the question until it's answered.
    private(set) var askingSignOut = false
    /// Copy link (or code) was just pressed: it reads "Copied" for a moment.
    private(set) var copied = false
    /// The methods unfolded in the card, and the groups disclosed in them, by title.
    private(set) var palette: Palette?
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
    /// The login the last sign-in or key was for: Try again goes there again.
    @ObservationIgnored private var aim = AccountStore.Aim.active
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
        (askingSignOut, copied, palette, editor, formPicker, formError, filled) = (false, false, nil, nil, nil, nil, [])
        store.dismissOutcome(provider)
        if store.flow(provider)?.step.live != true { Task { await store.refresh(provider) } }
    }

    /// Closing never stops a sign-in; an outcome goes, and the next open shows rest. A field or
    /// form goes, its secrets with it.
    func close() {
        guard isOpen else { return }
        isOpen = false
        (askingSignOut, palette, editor, formPicker, formError, filled) = (false, nil, nil, nil, nil, [])
        store.dismissOutcome(provider)
    }

    /// Esc: the methods or a form's choices fold, then the field or form, then the question go
    /// first. False when there's nothing to step back from, and the popup closes.
    func stepBack() -> Bool {
        if formPicker != nil {
            formPicker = nil
            return true
        }
        if palette != nil {
            palette = nil
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
        case .login: store.acceptsSignInInput(provider)
        // Through its sending too: a refused key brings the field back with the keys.
        case .key: showsKeyField || store.flow(provider)?.step == .signingIn
        case nil: false
        }
    }

    func enterSignInCode() {
        guard store.acceptsSignInInput(provider) else { return }
        palette = nil
        editor = .login
        store.openManualSignIn(provider)
    }

    func useDeviceCode() {
        closeEditor()
        Task { await store.useDeviceCode(provider, in: folder) }
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

    /// Sign in, Switch account, or a method picked from what's unfolded: the current method, or
    /// the one picked, for Add account's new login, a ⋯'s login, else the active one. A key or a
    /// platform opens its field or form, filled in with what's saved (Claude's settings, one for
    /// every login).
    func signIn(_ method: SignInMethod? = nil) {
        let aim: AccountStore.Aim =
            switch palette {
            case .add: .new
            case .login(let id): CLIProfiles.active(provider) == id ? .active : .login(id)
            case .methods, nil: .active
            }
        start(method, aim: aim)
    }

    /// Try again: the current method, for the login the last try was for.
    func tryAgain() { start(nil, aim: aim) }

    private func start(_ method: SignInMethod?, aim: AccountStore.Aim) {
        askingSignOut = false
        palette = nil
        guard let method = method ?? store.currentMethod(provider) else { return }
        self.aim = aim
        if method.opensEditor { return openEditor(method) }
        closeEditor()
        if aim == .new {
            store.addLogin(provider, method: method, in: folder)
        } else {
            store.signIn(provider, method: method, in: folder, aim: aim)
        }
    }

    /// Signed in, with logins Kore can keep side by side: the row's sign-in adds one.
    var addsLogins: Bool {
        guard case .signedIn = store.status(provider) else { return false }
        return !store.logins(provider).isEmpty
    }

    /// Add account: the methods that make a login of their own unfold (one alone starts at
    /// once); again, they fold.
    func toggleAdd() {
        askingSignOut = false
        let items = store.addMenu(provider)
        if palette != .add, items.count == 1, let method = items[0].method { return start(method, aim: .new) }
        (palette, disclosed) = (palette == .add ? nil : .add, [])
        if palette == .add { UILog.event("account-add-open", ["cli": provider]) }
    }

    /// A login's ⋯: its methods unfold (and, for an added one not in use, Remove); again, they fold.
    func toggleLoginMenu(_ id: String?) {
        askingSignOut = false
        (palette, disclosed) = (palette == .login(id) ? nil : .login(id), [])
        if palette == .login(id) { UILog.event("account-login-menu", ["cli": provider, "login": AccountStore.loginKey(id)]) }
    }

    /// The ⋯'s Remove, under its methods: an added login not in use, and whether it's a duplicate.
    var removable: AccountStore.Login? {
        guard case .login(let id?) = palette else { return nil }
        return store.logins(provider).first { $0.id == id && !$0.active }
    }

    func switchLogin(_ id: String?, _ pick: LoginPick) {
        palette = nil
        store.switchLogin(provider, to: id, pick)
    }

    func removeLogin(_ id: String) {
        palette = nil
        store.removeLogin(provider, id)
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
        (editor, formPicker, formError, filled) = (nil, nil, nil, [])
        if case .keyFailed = store.flow(provider)?.step { store.dismissOutcome(provider) }
    }

    /// The key, sent once; the field's view has already forgotten it.
    func submitKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        filled = []
        store.useKey(provider, key, aim: aim) { [weak self] landed in
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

    /// More than one method to pick from: the ⌄ shows.
    var hasMenu: Bool { store.methods(provider).count > 1 }

    /// The ⌄'s methods are unfolded.
    var methodsOpen: Bool { palette == .methods }

    /// The ⌄: the methods unfold above the account, every group closed; again, they fold.
    func toggleMethods() {
        askingSignOut = false
        (palette, disclosed) = (palette == .methods ? nil : .methods, [])
    }

    /// A group's row: its methods show under it, or go.
    func toggleGroup(_ title: String) {
        if disclosed.contains(title) { disclosed.remove(title) } else { disclosed.insert(title) }
    }

    /// The methods while they're unfolded: those the CLI's policy lists, in their groups; the
    /// ⌄'s with the current one checked.
    var methodsShown: [MethodMenuItem]? {
        switch palette {
        case .methods: store.menu(provider)
        case .add: store.addMenu(provider)
        case .login(let id): store.loginMenu(provider, id)
        case nil: nil
        }
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
    var room: CGFloat?
    private var store: AccountStore { .shared }
    private var product: String { chat.provider.usage.product }

    var body: some View {
        ComposerPopup(
            chat: chat, id: StoryID.Composer.account, room: room, isOpen: { state.isOpen }, stepBack: { state.stepBack() }, close: { state.close() },
            editing: { state.isEditing }
        ) {
            if case .platform(let platform) = state.editor {
                PlatformFormView(state: state, platform: platform)
                    .transition(.opacity.animation(Motion.fade))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // The methods, unfolded above the account (model-picker.html, "Account ⌄").
                    if let items = state.methodsShown {
                        MethodList(state: state, items: items)
                        Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
                    }
                    content
                        .onChange(of: store.acceptsSignInInput(chat.provider.id)) { _, accepting in
                            if !accepting, state.editor == .login { state.closeEditor() }
                        }
                    if store.acceptsSignInInput(chat.provider.id) {
                        LoginFallback(state: state, provider: chat.provider.id, serial: store.signInSerial(chat.provider.id))
                            .id(store.signInSerial(chat.provider.id))
                            .padding(.top, Space.sm)
                    }
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
        case .signedOut where store.logins(provider).count > 1:
            // Signed out (here or outside Kore): the other logins are still there to switch to.
            loginList(nil, signedIn: false)
        case .signedIn(let identity):
            VStack(alignment: .leading, spacing: 0) {
                header(AccountText.header(identity), menu: identity.changeable && !store.logins(provider).isEmpty)
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
    private func loginList(_ identity: AccountIdentity?, signedIn: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("\(chat.provider.name) logins").font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
                PrivacyButton()
                Spacer(minLength: 0)
            }
            .frame(minHeight: Size.MessageActions.button)
            .padding(.bottom, Space.xs)
            LoginList(state: state, provider: chat.provider.id, identity: identity)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.sm)
            row(signedIn: signedIn)
        }
    }

    /// The email in the title style, truncated in the middle; the spinner while the first read
    /// is under way. Where the CLI keeps several logins, its ⋯ (`menu`) as a listed login's.
    private func header(_ title: String, menu: Bool = false) -> some View {
        let email = state.identity?.email.map { $0 == title } ?? false
        let shown = email ? AccountPrivacy.shared.shown(title) : title
        return HStack(spacing: Space.md) {
            Text(shown)
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(shown)
            if email { PrivacyButton() }
            Spacer(minLength: 0)
            if store.status(chat.provider.id) == .unknown, store.isReading(chat.provider.id) {
                SpinningArc().frame(width: Size.spinner, height: Size.spinner)
            } else if menu {
                LoginMenuButton(state: state, login: CLIProfiles.active(chat.provider.id))
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
    /// the working chats it stops when it lands.
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
        case .starting, .browser, .code: return AccountText.switchCaption(working: store.workingChats(provider)).map { ($0, false) }
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
                    if state.addsLogins {
                        // Its palette holds the ways to sign in; each login's own are in its ⋯.
                        Button("Add account") { state.toggleAdd() }
                            .smallButton()
                            .storyID(id.part(.switch))
                            .tabStop(id.part(.switch)) { state.toggleAdd() }
                    } else {
                        Button("Switch account") { state.signIn() }
                            .smallButton()
                            .storyID(id.part(.switch))
                            .tabStop(id.part(.switch)) { state.signIn() }
                        if state.hasMenu { MethodMenuButton(state: state).storyID(id.part(.method)) }
                    }
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
                signInControl("Sign in", id: id) { state.signIn() }
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
            signInControl("Try again", id: id) { state.tryAgain() }
        case .signOutFailed:
            let words = Self.words(step)
            Text(words).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).help(words)
            Spacer(minLength: 0)
        case .timedOut:
            Text(AccountText.timedOut).lineLimit(1)
            Spacer(minLength: 0)
            signInControl("Try again", id: id) { state.tryAgain() }
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
    private func signInControl(_ title: String, id: StoryID, action: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: Space.sm) {
            Button(title, action: action)
                .smallButton(prominent: true)
                .storyID(id.part(.signIn))
                .tabStop(id.part(.signIn), action: action)
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
/// A login's ⋯ ends with Remove (Remove duplicate for a duplicate) where it can go.
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
            if let login = state.removable, let id = login.id {
                let title = login.duplicate ? AccountText.removeDuplicate : AccountText.remove
                let press: @MainActor @Sendable () -> Void = { state.removeLogin(id) }
                MethodRow(title: title, action: press)
                    .storyID(StoryID.Composer.accountMethod(title))
                    .tabStop(StoryID.Composer.accountMethod(title), action: press)
            }
        }
    }
}

/// One method, or a group (⌄ open, › closed), or a login's Remove; the hover fill under the
/// pointer.
private struct MethodRow: View {
    let title: String
    var hint: String?
    var depth = 0
    /// A group's ⌄ or ›; nil for a leaf.
    var open: Bool?
    var checked = false
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    init(item: MethodMenuItem, depth: Int, open: Bool, action: @escaping () -> Void) {
        (title, hint, self.depth, self.action) = (item.title, item.hint, depth, action)
        self.open = item.method == nil ? open : nil
        checked = item.checked && item.method != nil
    }

    init(title: String, action: @escaping () -> Void) { (self.title, self.action) = (title, action) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(TextStyle.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    if let hint {
                        Text(hint).font(TextStyle.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: Space.md)
                if let open {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(Glyph.chevron).foregroundStyle(Theme.secondary)
                } else if checked {
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
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A login's ⋯: its methods unfold in the card, Remove under them where it can go; again, they
/// fold.
private struct LoginMenuButton: View {
    let state: AccountState
    let login: String?

    var body: some View {
        let id = StoryID.Composer.accountLogin(AccountStore.loginKey(login)).part(.method)
        IconButton(
            symbol: "ellipsis", kind: .mini, font: Glyph.chevron, isOn: state.palette == .login(login), highlightsOnHover: false,
            help: "Account options"
        ) { state.toggleLoginMenu(login) }
            .storyID(id)
            .tabStop(id) { state.toggleLoginMenu(login) }
    }
}

/// With more than main, the CLI's logins in place of the header: a row each, the active one's
/// caption its plan and method and a ✓, main's "Main"; a login last read signed out says so, and
/// a duplicate says "Duplicate", quietly. A row switches to its login (its caption, under the
/// pointer, the working chats that stops); its ⋯ (on hover) holds its methods and Remove. Only the
/// active login's usage is read when the card opens; another's when its row is hovered. Every row
/// sits on the card's ground: one fill, under the pointer.
private struct LoginList: View {
    let state: AccountState
    let provider: String
    let identity: AccountIdentity?
    /// The row under the pointer, by login key: one at a time, as a pointer is.
    @StateObject private var hovered = Local<String?>(nil)
    private var store: AccountStore { .shared }

    var body: some View {
        let logins = store.logins(provider)
        let keys = logins.map { LoginUsage.Key(provider, $0, generation: store.generation(provider)) }
        // One visible-card clock updates every login's countdown; reads keep their own cache.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let usages = keys.map { LoginUsage.shared.state($0) }
            let labelWidth = LoginMeters.labelWidth(usages, now: context.date)
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(logins.enumerated()), id: \.element.id) { index, login in
                    let key = AccountStore.loginKey(login.id)
                    LoginRow(
                        state: state, login: login, caption: caption(login), plan: login.active ? identity?.plan : nil,
                        reading: login.active && identity == nil && store.status(provider) == .unknown,
                        usage: usages[index], usageKey: keys[index], now: context.date, labelWidth: labelWidth,
                        hovered: hovered.value == key) { on in
                        if on { hovered.value = key } else if hovered.value == key { hovered.value = nil }
                    }
                }
            }
        }
        .padding(.horizontal, -Space.sm)
        .task(id: keys) { await LoginUsage.shared.show(keys) }
    }

    private func caption(_ login: AccountStore.Login) -> String? {
        // The plan is the row's pill: the caption keeps only what the login is to Kore.
        let main = login.id == nil ? "Main" : nil
        let state = login.duplicate ? AccountText.duplicate : login.signedOut ? AccountText.loginSignedOut : nil
        let words = [main, state].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }
}

/// A login picked by hand: its row clicked, or pressed with Tab's ring on it. Only this file can
/// make one, so a switch of login is never Kore's own doing.
struct LoginPick {
    fileprivate init() {}
}

struct LoginRow: View {
    let state: AccountState
    let login: AccountStore.Login
    let caption: String?
    /// The active login's plan, as its account reads; a row's own usage reading says it first.
    let plan: String?
    /// Its account being read, just switched to: the spinner in the ✓'s place.
    let reading: Bool
    let usage: LoginUsage.State
    /// What a hover reads, for a login not in use.
    let usageKey: LoginUsage.Key
    let now: Date
    let labelWidth: CGFloat
    /// Under the pointer: the list keeps one row hovered at a time.
    let hovered: Bool
    let hover: (Bool) -> Void
    @Environment(TabStops.self) private var stops: TabStops?

    /// How long the pointer rests on a row before its login is read: passing over it reads nothing.
    static let hoverRead: Duration = .milliseconds(300)

    var body: some View {
        let id = StoryID.Composer.accountLogin(AccountStore.loginKey(login.id))
        let title = login.email.map(AccountPrivacy.shared.shown) ?? (login.id == nil ? "Main account" : "Account")
        let menuOpen = state.palette == .login(login.id)
        Button { if !login.active { state.switchLogin(login.id, LoginPick()) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    Text(title)
                        .font(login.active ? TextStyle.title : TextStyle.body)
                        .foregroundStyle(login.active ? Theme.text : Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(title)
                    Spacer(minLength: Space.md)
                    if let pill = LoginRow.pill(usage, plan: plan) { PlanPill(text: pill) }
                    // One trailing slot in every row, ✓ or (on hover) ⋯: the pills line up beside it.
                    ZStack {
                        if hovered || menuOpen {
                            LoginMenuButton(state: state, login: login.id)
                        } else if reading {
                            SpinningArc().frame(width: Size.spinner, height: Size.spinner)
                        } else if login.active {
                            Image(systemName: "checkmark").font(TextStyle.label).foregroundStyle(Theme.accent)
                        }
                    }
                    // A fixed size: hovering never changes the row's.
                    .frame(width: Size.MessageActions.button, height: Size.MessageActions.button)
                }
                if let caption {
                    Text(caption).font(TextStyle.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                }
                // Under the slot too: the bars run to the card's edge.
                LoginMeters(state: usage, signedOut: login.signedOut, now: now, labelWidth: labelWidth)
                    .padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, minHeight: Size.Picker.method, alignment: .leading)
            .hoverFill(hovered && !login.active, Theme.Row.hover(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .onHover(perform: hover)
        .storyID(id)
        .storyAction(id.part(.hover)) { hover(true) }
        .task(id: !login.active && (hovered || stops?.current == id.raw)) {
            guard !login.active, hovered || stops?.current == id.raw else { return }
            try? await Task.sleep(for: Self.hoverRead)
            guard !Task.isCancelled else { return }
            LoginUsage.shared.hover(usageKey)
        }
        .tabStop(id) { state.switchLogin(login.id, LoginPick()) }
        .accessibilityAddTraits(login.active ? .isSelected : [])
    }

    /// The row's plan pill: its own usage reading's plan, else the active login's.
    static func pill(_ usage: LoginUsage.State, plan: String?) -> String? {
        if case .ready(let reading, _) = usage {
            let perToken = if case .perToken = reading.account.access { true } else { false }
            if let pill = AccountPrivacy.pill(plan: reading.account.plan, perToken: perToken) { return pill }
        }
        return AccountPrivacy.pill(plan: plan, perToken: false)
    }
}

/// A login's plan, small, on its row: "Max", "Team", "API".
private struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TextStyle.caption)
            .fontWeight(.medium)
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .padding(.horizontal, Space.xs)
            .frame(height: Size.Account.pill)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Size.Account.pillRadius))
            .fixedSize()
    }
}

/// Privacy mode's block beside the card's heading: a bare eye while emails show; a crossed eye
/// and "Private" in the accent while they're masked. Kept across opens and launches.
struct PrivacyButton: View {
    @StateObject private var hovered = Local(false)

    var body: some View {
        let privacy = AccountPrivacy.shared
        let id = StoryID.Composer.accountPrivacy
        let flip: @MainActor () -> Void = { privacy.on.toggle() }
        Button(action: flip) {
            HStack(spacing: Space.xs) {
                Image(systemName: privacy.on ? "eye.slash" : "eye").font(TextStyle.caption)
                if privacy.on { Text("Private").font(TextStyle.caption) }
            }
            .foregroundStyle(privacy.on ? Theme.accent : hovered.value ? Theme.text : Theme.secondary)
            .padding(.horizontal, Space.sm)
            .frame(height: Size.smallButton)
            .background(privacy.on ? Theme.Account.privateFill : hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(privacy.on ? "Show emails" : "Hide emails")
        .storyID(id)
        .tabStop(id, action: flip)
        .accessibilityLabel(Text("Private emails"))
        .accessibilityValue(Text(privacy.on ? "On" : "Off"))
    }
}


/// OAuth input exists only while this particular fallback field is on screen.
private struct LoginFallback: View {
    let state: AccountState
    let provider: String
    let serial: Int
    @StateObject private var input = Local("")
    @StateObject private var sending = Local(false)
    @StateObject private var reason = Local<String?>(nil)
    @FocusState private var focused: Bool
    private var store: AccountStore { .shared }
    private var callback: Bool { provider == "codex" }
    private var fieldID: StoryID { StoryID.Composer.accountField("login") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                // The button turns into the field: its placeholder says what goes in.
                if state.editor == .login {
                    SecureField("", text: $input.value, prompt: Text(callback ? "Callback URL" : "Sign-in code").foregroundStyle(Theme.tertiary))
                        .focused($focused)
                        .fieldWell(focused: focused)
                        .storyID(fieldID)
                        .onSubmit(submit)
                        .onAppear { focused = true }
                    Button("Submit", action: submit)
                        .smallButton(prominent: true)
                        .disabled(sending.value || input.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .storyID(fieldID.part(.submit))
                } else {
                    Button(callback ? "Paste callback URL…" : "Enter sign-in code…") { state.enterSignInCode() }
                        .smallButton()
                        .storyID(fieldID.part(.open))
                        .tabStop(fieldID.part(.open)) { state.enterSignInCode() }
                }
                if store.methods(provider).contains(where: { $0.kind == .deviceCode }) {
                    Button("Use Device Code") { state.useDeviceCode() }
                        .smallButton()
                        .storyID(fieldID.part(.method))
                        .tabStop(fieldID.part(.method)) { state.useDeviceCode() }
                }
            }
            if state.editor == .login, let error = reason.value {
                Text(error).font(TextStyle.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { input.value = "" }
    }

    private func submit() {
        let sent = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending.value, !sent.isEmpty else { return }
        input.value = ""
        reason.value = nil
        sending.value = true
        Task {
            defer { sending.value = false }
            do {
                try await store.submitSignIn(sent, provider: provider, serial: serial)
            } catch let reason as LoginCallback.Failure {
                self.reason.value = reason.errorDescription
            } catch {
                // A CLI/network error may echo a credential: the field uses fixed words.
                self.reason.value = "Couldn't finish signing in. Try again or start a new sign-in."
            }
        }
    }
}
