import AppKit
import SwiftUI

// The local link's two views: the card a ring shows (Allow for this session / Deny), and the
// title row's mark while a companion is linked. Neither exists until a ring arrives.

/// The title row's mark, shown only while a companion is connected: a lit link glyph. The hover
/// is its one line; a click opens the popup with the recent actions and Disconnect.
struct LinkMarkButton: View {
    let mark: LinkMark
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var frame = Held(CGRect.zero)

    var body: some View {
        Button {
            LinkPanel.toggleMarkPopup(mark, under: frame.value)
        } label: {
            Image(systemName: "link")
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : Theme.accent)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { LinkPanel.anchorWindow = $0 })
        .help(mark.line)
        .accessibilityLabel(Text(mark.line))
    }
}

/// The mark's popup: the companion and its state, the last actions it took, and Disconnect.
struct LinkMarkPopup: View {
    let mark: LinkMark
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(mark.line).font(Chrome.bodyMedium).foregroundStyle(Theme.text)
            if !mark.recent.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(mark.recent.indices, id: \.self) { i in
                        Text(mark.recent[i]).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            Button("Disconnect") {
                close()
                mark.disconnect()
            }
            .buttonStyle(SubtleButtonStyle())
            .storyID(StoryID.Link.disconnect) {
                close()
                mark.disconnect()
            }
        }
        .padding(Space.lg)
        .frame(width: Size.Link.popupWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .storyID(StoryID.Link.popup)
    }
}

/// The card's answer: Deny, Allow (follow and act under Kore's rules), or Allow with full control
/// (also arrange chats, tabs, boards, windows and history, for this run only).
package enum LinkCardChoice: Sendable { case deny, allow, allowFull }

/// What a ring asks: "<name> wants to connect". Deny is the default (Return and Esc); the Allows
/// take a moment to enable, so a key already on its way can't press them.
struct LinkCardView: View {
    let name: String
    let answer: (LinkCardChoice) -> Void
    @StateObject private var ready = Local(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("\(name) wants to connect").font(Chrome.bodyMedium).foregroundStyle(Theme.text)
            Text("It could follow your chats and act in them under Kore's rules, until Kore quits.")
                .font(Chrome.label)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button("Allow with full control") { answer(.allowFull) }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(!ready.value)
                    .help("It could also open, close and arrange chats, tabs, boards and windows, until Kore quits.")
                    .storyID(StoryID.Link.allowFull) { if ready.value { answer(.allowFull) } }
                Button("Allow for this session") { answer(.allow) }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(!ready.value)
                    .storyID(StoryID.Link.allow) { if ready.value { answer(.allow) } }
                Button("Deny") { answer(.deny) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .storyID(StoryID.Link.deny) { answer(.deny) }
            }
        }
        .padding(Space.lg)
        .frame(width: Size.Link.cardWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .onExitCommand { answer(.deny) }
        .storyID(StoryID.Link.card)
        .task {
            try? await Task.sleep(for: Size.Link.allowDelay)
            ready.value = true
            LinkPanel.allowsReady = true
        }
    }
}

/// A device asking this Mac (phase 18): a phone joining from the Add device window, or a phone's
/// new fingerprint key. The card shows what Tailscale says of it, never only the name it gives.
package struct DeviceCardInfo: Equatable, Sendable {
    /// "Pixel 9 wants to join", "Pixel 9: new fingerprint key".
    package var title: String
    /// What Allow lets it do, one line.
    package var note: String
    /// The Tailscale node's name, its address and login, and when it first knocked.
    package var node: String
    package var address: String
    package var login: String
    package var firstSeen: Date

    package init(title: String, note: String, node: String, address: String, login: String, firstSeen: Date) {
        self.title = title
        self.note = note
        self.node = node
        self.address = address
        self.login = login
        self.firstSeen = firstSeen
    }
}

/// The device card: Deny is the default (Return and Esc); Allow takes the mouse only (it never
/// takes focus, so no key can press it), and only once the card has been up a second, counted
/// again whenever the card takes the keys back.
struct DeviceCardView: View {
    let info: DeviceCardInfo
    @ObservedObject var armed: Local<Bool>
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(info.title).font(Chrome.bodyMedium).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: Space.xs) {
                line(info.node)
                line("\(info.address) · \(info.login)")
                line("First seen \(info.firstSeen.formatted(date: .omitted, time: .shortened))")
            }
            Text(info.note).font(Chrome.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button("Allow") { if armed.value { answer(true) } }
                    .buttonStyle(SubtleButtonStyle())
                    .focusable(false)
                    .disabled(!armed.value)
                    .storyID(StoryID.Link.deviceAllow) { if armed.value { answer(true) } }
                Button("Deny") { answer(false) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .storyID(StoryID.Link.deviceDeny) { answer(false) }
            }
        }
        .padding(Space.lg)
        .frame(width: Size.Link.deviceCardWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .onExitCommand { answer(false) }
        .storyID(StoryID.Link.deviceCard)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
    }
}

/// A borderless floating panel for the card and the mark's popup: Kore's own popup look, outside
/// any one window (a ring can come while Kore is in the background).
@MainActor
package enum LinkPanel {
    private static var card: NSPanel?
    private static var popup: NSPanel?
    /// The window whose title row holds the mark the popup opens under.
    static weak var anchorWindow: NSWindow?

    /// Shows the card over the front window (or the screen's middle), and brings Kore forward.
    package static func showCard(name: String, answer: @escaping (LinkCardChoice) -> Void) {
        closeCard()
        var answered = false
        let panel = makePanel(LinkCardView(name: name) { choice in
            guard !answered else { return }
            answered = true
            closeCard()
            answer(choice)
        })
        let size = panel.frame.size
        let base = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: base.midX - size.width / 2, y: base.midY - size.height / 2))
        card = panel
        // Brought forward for the user; never under a storyline host, which runs out of sight.
        if !StoryHost.installed { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
    }

    package static func closeCard() {
        card?.orderOut(nil)
        card = nil
        allowsReady = false
    }

    private static var deviceCard: NSPanel?
    private static var deviceArming: Task<Void, Never>?
    private static var deviceKeyWatch: NSObjectProtocol?
    private static var deviceArmed: Local<Bool>?

    /// Shows a device card over the front window, answered once. It comes forward but takes the
    /// keys only while Kore is frontmost: a phone knocking never pulls focus from another app.
    package static func showDeviceCard(_ info: DeviceCardInfo, answer: @escaping (Bool) -> Void) {
        closeDeviceCard()
        let armed = Local(false)
        var answered = false
        let panel = makePanel(DeviceCardView(info: info, armed: armed) { allow in
            guard !answered else { return }
            answered = true
            closeDeviceCard()
            answer(allow)
        })
        let size = panel.frame.size
        let base = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: base.midX - size.width / 2, y: base.midY - size.height / 2))
        deviceCard = panel
        deviceArmed = armed
        // Each time the card takes the keys (again), Allow waits its second anew.
        deviceKeyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { if let armed = deviceArmed { arm(armed) } }
        }
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        arm(armed)
    }

    private static func arm(_ armed: Local<Bool>) {
        armed.value = false
        deviceArming?.cancel()
        deviceArming = Task { @MainActor in
            try? await Task.sleep(for: Size.Link.deviceAllowDelay)
            guard !Task.isCancelled else { return }
            armed.value = true
        }
    }

    package static func closeDeviceCard() {
        deviceArming?.cancel()
        deviceArming = nil
        if let deviceKeyWatch { NotificationCenter.default.removeObserver(deviceKeyWatch) }
        deviceKeyWatch = nil
        deviceCard?.orderOut(nil)
        deviceCard = nil
        deviceArmed = nil
    }

    /// A device card is up.
    package static var deviceCardOpen: Bool { deviceCard != nil }

    /// The open card's Allows take a press: its moment has passed since the card was drawn.
    package fileprivate(set) static var allowsReady = false

    /// The card is up.
    package static var cardOpen: Bool { card != nil }

    static func toggleMarkPopup(_ mark: LinkMark, under rect: CGRect) {
        if popup != nil {
            closePopup()
            return
        }
        let panel = makePanel(LinkMarkPopup(mark: mark) { closePopup() }, closesOnResign: true)
        if let window = anchorWindow {
            // `rect` is in the window's content, top-left origin.
            let top = window.frame.maxY - (window.frame.height - window.contentLayoutRect.height) - rect.maxY
            let point = NSPoint(x: window.frame.minX + rect.maxX - panel.frame.width, y: window.frame.minY + top - panel.frame.height)
            panel.setFrameOrigin(NSPoint(x: point.x, y: min(point.y, window.frame.maxY - panel.frame.height)))
        }
        popup = panel
        panel.makeKeyAndOrderFront(nil)
    }

    package static func closePopup() {
        popup?.orderOut(nil)
        popup = nil
    }

    private static func makePanel(_ view: some View, closesOnResign: Bool = false) -> NSPanel {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.closesOnResign = closesOnResign
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // A panel hides while its app isn't frontmost by default: the card stays up until it's
        // answered, so a click elsewhere can't leave a ring waiting unseen (and a storyline host
        // that isn't frontmost still finds it). The popup closes on losing keys anyway.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        return panel
    }

    /// A borderless panel that takes keys (the card's Return and Esc), and the popup's that
    /// closes when it loses them.
    private final class KeyPanel: NSPanel {
        var closesOnResign = false
        override var canBecomeKey: Bool { true }
        override func resignKey() {
            super.resignKey()
            if closesOnResign { MainActor.assumeIsolated { LinkPanel.closePopup() } }
        }
    }
}
