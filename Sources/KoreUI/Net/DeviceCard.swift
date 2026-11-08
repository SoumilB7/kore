import AppKit
import HostClient
import SwiftUI

/// A device asking this Mac (frame B): a phone or box joining, a box's claim, a phone's new
/// fingerprint key. The card shows Tailscale's facts about the node (its name, address, login,
/// first seen), never only the name the device gives itself; a box's card adds its device code.
package struct DeviceCardInfo: Equatable, Sendable {
    /// "Pixel 9 wants to join", "Pixel 9: new fingerprint key".
    package var title: String
    /// What Allow lets it do, one sentence.
    package var note: String
    /// The Tailscale node's name, its address and login, and when it first knocked.
    package var node: String
    package var address: String
    package var login: String
    package var firstSeen: Date
    package var kind: DeviceRow.Kind
    /// The name it gives itself ("Pixel 9"), for the timed-out card.
    package var name: String
    /// A box's device id: its first 8 hex digits are the code `kore-host join` printed.
    package var device: UUID?

    package init(
        title: String, note: String, node: String, address: String, login: String, firstSeen: Date, kind: DeviceRow.Kind = .phone, name: String? = nil,
        device: UUID? = nil
    ) {
        self.title = title
        self.note = note
        self.node = node
        self.address = address
        self.login = login
        self.firstSeen = firstSeen
        self.kind = kind
        self.name = name ?? title.components(separatedBy: " wants to join").first ?? title
        self.device = device
    }

    /// A phone joining from the Add device window.
    package static func phone(name: String, node: String, address: String, login: String, firstSeen: Date) -> DeviceCardInfo {
        DeviceCardInfo(
            title: "\(name) wants to join", note: "It could read your chats and send in them, within each chat's mode.", node: node, address: address,
            login: login, firstSeen: firstSeen, kind: .phone, name: name)
    }

    /// A box's claim (New box…, or a peer in the Welcome "+" list), and a box waiting at a box.
    package static func box(name: String, node: String, address: String, login: String, firstSeen: Date, device: UUID?) -> DeviceCardInfo {
        DeviceCardInfo(
            title: "\(name) wants to join",
            note: "Check that the device code matches what \(name) printed. This Mac could then run chats, terminals and syncs there.", node: node,
            address: address, login: login, firstSeen: firstSeen, kind: .box, name: name, device: device)
    }

    /// "7F3A 91C2": the device id's first 8 hex digits, in two groups to compare by eye.
    package var code: String? {
        guard let device else { return nil }
        let hex = device.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        return String(hex.prefix(4)) + " " + String(hex.suffix(4))
    }

    /// "just now", "40 s ago", then as Devices says it.
    package static func seen(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        return DevicesWords.ago(date, now: now)
    }
}

/// The card's state: asking (Allow armed or not yet), or stopped waiting.
@MainActor
final class DeviceCardState: ObservableObject {
    @Published var armed = false
    @Published var stopped = false
    let info: DeviceCardInfo
    init(_ info: DeviceCardInfo) { self.info = info }
}

/// The card. Deny is the default (Return and Esc). Allow takes the mouse only (it never takes
/// focus, so no key can press it) and only once the card has been up a second, counted again
/// whenever the card takes the keys back; until then it's drawn in tertiary and does nothing
/// (no timer or words: the colour coming up is the only cue). Stopped waiting, the facts and
/// Allow go and Close is the one button.
struct DeviceCardView: View {
    @ObservedObject var state: DeviceCardState
    let answer: @MainActor (Bool) -> Void
    let close: @MainActor () -> Void

    var body: some View {
        let info = state.info
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                NetGlyph(kind: info.kind.glyph).foregroundStyle(Theme.Net.glyph)
                Text(state.stopped ? "\(info.name) stopped waiting" : info.title)
                    .font(Theme.Net.title)
                    .foregroundStyle(state.stopped ? Theme.secondary : Theme.text)
                    .lineLimit(1)
            }
            .padding(.bottom, Space.lg)
            if state.stopped {
                Text("Nothing was allowed. Join again from \(info.name).").font(Theme.Net.line).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.xl)
                HStack {
                    Spacer(minLength: 0)
                    Button(action: close) { hinted("Close") }
                        .buttonStyle(NetButtonStyle(look: .go))
                        .keyboardShortcut(.defaultAction)
                        .storyID(StoryID.Net.cardClose, press: close)
                }
            } else {
                facts(info).padding(.bottom, Space.lg)
                Text(info.note).font(Theme.Net.line).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.xl)
                HStack(spacing: Space.md) {
                    Spacer(minLength: 0)
                    Button("Allow") { if state.armed { answer(true) } }
                        .buttonStyle(NetButtonStyle(look: state.armed ? .plain : .dim))
                        .focusable(false)
                        .animation(Motion.fade, value: state.armed)
                        .storyID(StoryID.Net.allow) { if state.armed { answer(true) } }
                    Button { answer(false) } label: { hinted("Deny") }
                        .buttonStyle(NetButtonStyle(look: .go))
                        .keyboardShortcut(.defaultAction)
                        .storyID(StoryID.Net.deny) { answer(false) }
                }
            }
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.vertical, Space.xxl)
        .frame(width: Size.Net.cardWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .onExitCommand { state.stopped ? close() : answer(false) }
        .storyID(StoryID.Net.card)
    }

    private func hinted(_ title: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(title)
            Text("↩").font(Theme.Net.hint).foregroundStyle(Theme.Net.onAccentHint)
        }
    }

    private func facts(_ info: DeviceCardInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.xxs + 1) {
            fact("Tailscale", info.node, mono: true)
            fact("Address", info.address, mono: true)
            fact("Signed in as", info.login)
            fact("First seen", DeviceCardInfo.seen(info.firstSeen, now: Date()))
            if let code = info.code {
                fact("Device", code, mono: true, strong: true).help(info.device?.uuidString.lowercased() ?? "")
            }
        }
    }

    private func fact(_ name: String, _ value: String, mono: Bool = false, strong: Bool = false) -> some View {
        GridRow {
            Text(name).font(Theme.Net.line).foregroundStyle(Theme.tertiary).frame(width: Size.Net.factsColumn, alignment: .leading)
            Text(value)
                .font(mono ? Theme.Net.mono : Theme.Net.line)
                .foregroundStyle(strong || !mono ? Theme.text : Theme.Net.monoText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

extension DeviceRow.Kind {
    var glyph: NetGlyph.Kind {
        switch self {
        case .mac: .mac
        case .box: .box
        case .phone: .phone
        }
    }
}

/// The card's floating panel: over the front window, outside any one window (a device can knock
/// while Kore is in the background). It comes forward but takes the keys only while Kore is
/// frontmost: a phone knocking never pulls focus from another app.
@MainActor
package enum DeviceCardPanel {
    private static var panel: NSPanel?
    private static var state: DeviceCardState?
    private static var arming: Task<Void, Never>?
    private static var closing: Task<Void, Never>?
    private static var keyWatch: NSObjectProtocol?
    /// How long Allow waits (UX pass: 1 s).
    package static var allowDelay: Duration = Size.Link.deviceAllowDelay

    /// Shows a card, answered once.
    package static func show(_ info: DeviceCardInfo, answer: @escaping (Bool) -> Void) {
        close()
        let state = DeviceCardState(info)
        var answered = false
        let view = DeviceCardView(state: state) { allow in
            guard !answered else { return }
            answered = true
            close()
            answer(allow)
        } close: {
            close()
        }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // It stays until it's answered: a click elsewhere can't leave a device waiting unseen.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        let size = panel.frame.size
        let base = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: base.midX - size.width / 2, y: base.midY - size.height / 2))
        self.panel = panel
        self.state = state
        // Each time the card takes the keys (again), Allow waits its second anew.
        keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { arm() }
        }
        if NSApp.isActive { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        arm()
    }

    private static func arm() {
        guard let state, !state.stopped else { return }
        state.armed = false
        arming?.cancel()
        let delay = allowDelay
        arming = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            state.armed = true
        }
    }

    /// The device stopped waiting (the Add window ended, it gave up) before an answer: the card
    /// stays so it doesn't vanish under the pointer, says so, and closes on its own after 5 s.
    package static func stopWaiting() {
        guard let state, !state.stopped else { return close() }
        arming?.cancel()
        state.armed = false
        state.stopped = true
        if let panel, let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        closing = Task { @MainActor in
            try? await Task.sleep(for: Size.Net.timedOutFor)
            guard !Task.isCancelled else { return }
            close()
        }
    }

    package static func close() {
        arming?.cancel()
        arming = nil
        closing?.cancel()
        closing = nil
        if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
        keyWatch = nil
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    /// A card is up (asking or stopped).
    package static var isOpen: Bool { panel != nil }
    /// It's asking, Allow armed.
    package static var armed: Bool { state?.armed == true }
    package static var stopped: Bool { state?.stopped == true }

    private final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
