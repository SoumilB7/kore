import AppKit
import KoreCore
import Observation
import SwiftUI

/// The Account popup's state in one chat: open or not, and the Sign out question. The account
/// and any sign-in under way are the app's (`AccountStore`), shared by every chat of the CLI.
@MainActor @Observable
final class AccountState {
    private(set) var isOpen = false
    /// Sign out asked; the row is the question until it's answered.
    private(set) var askingSignOut = false
    /// Copy link (or code) was just pressed: it reads "Copied" for a moment.
    private(set) var copied = false
    /// The ⌄ menu's items as a storyline host sees them: under a host the native menu never
    /// pops up (its tracking loop would hold the run), and an item is picked by its title.
    private(set) var hostMenu: [MenuItem]?
    @ObservationIgnored private(set) var provider = ""
    /// When Sign out asked (system uptime): a "Yes" within a double-click of it is the Sign out
    /// click's second half, and is ignored.
    @ObservationIgnored private var askedAt: TimeInterval = 0
    @ObservationIgnored private var copiedTimer: Task<Void, Never>?

    /// One of the ⌄ menu's items.
    struct MenuItem: Equatable {
        let method: SignInMethod
        let checked: Bool
        /// A separator goes before it.
        let separated: Bool
    }

    private var store: AccountStore { .shared }

    /// Opens on what the store has, and reads the account again behind it.
    func open(provider: String) {
        self.provider = provider
        isOpen = true
        (askingSignOut, copied, hostMenu) = (false, false, nil)
        store.dismissOutcome(provider)
        if store.flow(provider)?.step.live != true { Task { await store.refresh(provider) } }
    }

    /// Closing never stops a sign-in; an outcome goes, and the next open shows rest.
    func close() {
        guard isOpen else { return }
        isOpen = false
        (askingSignOut, hostMenu) = (false, nil)
        store.dismissOutcome(provider)
    }

    /// Esc: the question goes first. False when there's none, and the popup closes.
    func stepBack() -> Bool {
        if hostMenu != nil {
            hostMenu = nil
            return true
        }
        guard askingSignOut else { return false }
        askingSignOut = false
        return true
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

    /// Sign in, Switch account, Try again: the current method, or the one picked.
    func signIn(_ method: SignInMethod? = nil) {
        askingSignOut = false
        hostMenu = nil
        store.signIn(provider, method: method)
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

    /// The ⌄ menu: every method the CLI's login offers, those Kore can't run off and after a
    /// separator, the current one checked.
    var menuItems: [MenuItem] {
        let methods = store.methods(provider)
        let current = store.currentMethod(provider)?.id
        let firstOff = methods.firstIndex { !$0.runs }
        return methods.enumerated().map { index, method in
            MenuItem(method: method, checked: method.id == current, separated: index == firstOff && index > 0)
        }
    }

    func showHostMenu() { hostMenu = menuItems }

    /// A host's pick from the menu, as a click on the item does.
    func pickHostMenu(_ title: String) {
        guard let item = hostMenu?.first(where: { $0.method.label == title }), item.method.runs else { return }
        signIn(item.method)
    }

    /// The popup's lines as they read, for a storyline's checks: the header, the caption, then
    /// the action row's words ("you@example.com", "Claude Max · Claude.ai", "Waiting for the
    /// browser…").
    func lines(product: String) -> [String] {
        switch store.status(provider) {
        case .signedIn(let identity):
            let row: [String] = identity.changeable || store.flow(provider) != nil ? rowWords(product: product, signedIn: true) : [AccountText.cantChange]
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
        if askingSignOut { return [AccountText.askSignOut(product)] }
        guard let step = store.flow(provider)?.step else { return signedIn ? [] : [AccountText.signedOut(product)] }
        return [AccountRow.words(step)]
    }
}

/// The / menu's Account, in Usage's place and frame (account-popup.html §6): this chat's CLI
/// only. Signed in, the email, a caption (plan · method · organisation) and one row with Switch
/// account and Sign out; signed out, one row, "Claude Code isn't signed in." with Sign in ⌄.
/// The action row is the only line that changes: it runs the sign-in, the Sign out question
/// and their outcomes. A login Kore can't change has one tertiary line in its place.
struct AccountPopup: View {
    let chat: Chat
    let state: AccountState
    private var store: AccountStore { .shared }
    private var product: String { chat.provider.usage.product }

    var body: some View {
        ComposerPopup(chat: chat, id: StoryID.Composer.account, stepBack: { state.stepBack() }, close: { state.close() }) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let provider = chat.provider.id
        switch store.status(provider) {
        case .signedIn(let identity):
            VStack(alignment: .leading, spacing: 0) {
                header(AccountText.header(identity))
                let caption = AccountText.caption(identity)
                Text(caption)
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(caption)
                if identity.changeable || store.flow(provider) != nil {
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
            AccountRow(state: state, flow: flow, signedIn: signedIn, product: product)
            if let caption = caption(flow, signedIn: signedIn) {
                Text(caption)
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(caption)
                    .transition(.opacity.animation(Motion.fade))
            }
        }
    }

    /// Under the question, what a sign-out reaches; under a switch under way, what it means for
    /// the open chats.
    private func caption(_ flow: AccountStore.Flow?, signedIn: Bool) -> String? {
        if state.askingSignOut { return AccountText.signOutCaption(working: store.workingChats(chat.provider.id)) }
        guard signedIn, let flow, flow.switching else { return nil }
        switch flow.step {
        case .starting, .browser, .code: return AccountText.moving
        default: return nil
        }
    }
}

/// The action row, 26 high: at rest, the CLI's buttons; then the question, the flow and its
/// outcome, each fading in where the last was. Nothing in it moves.
private struct AccountRow: View {
    let state: AccountState
    let flow: AccountStore.Flow?
    let signedIn: Bool
    let product: String

    /// The row's words for a step, as `AccountState.lines` reports them.
    static func words(_ step: AccountStore.Step) -> String {
        switch step {
        case .starting: AccountText.starting
        case .browser: AccountText.browser
        case .code(let code, _): "Enter \(code)"
        case .signingOut: AccountText.signingOut
        case .signedIn: AccountText.signedIn
        case .switched: AccountText.switched
        case .same: AccountText.same
        case .failed(let reason): AccountText.signInFailed(reason)
        case .signOutFailed(let reason): AccountText.signOutFailed(reason)
        case .timedOut: AccountText.timedOut
        }
    }

    private var key: String {
        if state.askingSignOut { return "ask" }
        guard let step = flow?.step else { return signedIn ? "in" : "out" }
        return Self.words(step)
    }

    var body: some View {
        let id = StoryID.Composer.account
        HStack(spacing: Space.md) {
            if state.askingSignOut {
                Text(AccountText.askSignOut(product)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Yes, sign out") { state.signOut() }
                    .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                    .storyID(id.part(.allow))
                Button("No, go back") { state.cancelSignOut() }
                    .buttonStyle(SubtleButtonStyle(small: true))
                    .storyID(id.part(.cancel))
            } else if let step = flow?.step {
                flowLine(step, id: id)
            } else if signedIn {
                Button("Switch account") { state.signIn() }
                    .buttonStyle(SubtleButtonStyle(small: true))
                    .storyID(id.part(.switch))
                Button("Sign out") { state.askSignOut() }
                    .buttonStyle(SubtleButtonStyle(small: true))
                    .storyID(id.part(.signOut))
                Spacer(minLength: 0)
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
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func flowLine(_ step: AccountStore.Step, id: StoryID) -> some View {
        switch step {
        case .starting:
            spinning(AccountText.starting)
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
        case .signingOut:
            spinning(AccountText.signingOut)
        case .signedIn, .switched, .same:
            let words = Self.words(step)
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark").font(Glyph.chevron)
                Text(words).lineLimit(1).truncationMode(.tail)
            }
            .help(step == .same ? AccountText.sameHelp : words)
            Spacer(minLength: 0)
        case .failed(let reason):
            let words = AccountText.signInFailed(reason)
            Text(words).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).help(words)
            Spacer(minLength: 0)
            signInControl("Try again", id: id)
        case .signOutFailed(let reason):
            let words = AccountText.signOutFailed(reason)
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

    /// Sign in (or Try again) and the ⌄ of methods.
    private func signInControl(_ title: String, id: StoryID) -> some View {
        HStack(spacing: Space.xxs) {
            Button(title) { state.signIn() }
                .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                .storyID(id.part(.signIn))
            MethodMenuButton(state: state)
                .storyID(id.part(.method), press: { state.showHostMenu() })
        }
    }
}

/// The ⌄: a native menu of the CLI's sign-in methods under it. Under a storyline host the
/// menu's items are handed over instead.
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
        for item in state.menuItems {
            if item.separated { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: item.method.label, action: #selector(MethodPicker.pick(_:)), keyEquivalent: "")
            entry.target = picker
            entry.representedObject = item.method.id
            entry.isEnabled = item.method.runs
            entry.state = item.checked ? .on : .off
            menu.addItem(entry)
        }
        let box = frame.value
        let point = NSPoint(x: box.minX, y: content.isFlipped ? box.maxY + Space.xs : content.bounds.height - box.maxY - Space.xs)
        // Runs until the menu closes; the picker lives as long.
        menu.popUp(positioning: nil, at: point, in: content)
        withExtendedLifetime(picker) {}
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
