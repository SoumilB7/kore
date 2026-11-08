import AppKit
import HostClient
import SwiftUI

/// What the Welcome's box view and the box popup share: a box's one line with its action, and the Add a
/// box… field.

/// A box's one line, and its action after a dot ("Stopped on mybox · Start"). Copy puts the
/// command in the pasteboard; Set up agents and Fix open the agents popup under the line (and
/// `opened` closes the popup it's in, one at a time); the rest are the list's.
struct BoxNoteLine: View {
    let note: BoxList.Note
    let alias: String
    var opened: (() -> Void)?
    @StateObject private var anchor = Held<NSView?>(nil)
    @StateObject private var copied = Local(false)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(note.line).foregroundStyle(Theme.tertiary).lineLimit(2).textSelection(.enabled)
            if let action = note.action {
                Text("·").foregroundStyle(Theme.tertiary)
                Button(copied.value ? "Copied" : action.title) { take(action) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
        }
        .font(Chrome.caption)
        .background(BoxAnchor { anchor.value = $0 })
    }

    private func take(_ action: BoxList.Action) {
        switch action {
        case .copy(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied.value = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied.value = false
            }
        case .setUpAgents, .differences:
            BoxCard.shared.showAgents(alias, under: anchor.value)
            opened?()
        default:
            Task { await BoxList.shared.act(action, on: alias) }
        }
    }
}

/// The field of Add a box…: an SSH alias or `user@host[:port]`. Return adds what's typed when
/// it's one (`BoxList.alias(_:)`), Esc gives up.
struct BoxAliasField: View {
    @Binding var text: String
    let add: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("SSH alias or user@host").foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Chrome.label)
            .focused($focused)
            .fieldWell(focused: focused)
            .onSubmit { if let alias = BoxList.alias(text) { add(alias) } }
            .onExitCommand(perform: cancel)
            .onAppear { focused = true }
    }
}

/// A box's status: connected (filled, green), offline (filled, dim), not set up (a ring), not
/// asked yet (a faint ring).
struct StatusDot: View {
    enum State { case connected, offline, notSetUp, unknown }
    let state: State

    var body: some View {
        let size = Size.statusPoint
        Group {
            switch state {
            case .connected: Circle().fill(Theme.success)
            case .offline: Circle().fill(Theme.tertiary)
            case .notSetUp: Circle().strokeBorder(Theme.tertiary, lineWidth: Stroke.hairline * 1.5)
            case .unknown: Circle().strokeBorder(Theme.border, lineWidth: Stroke.hairline * 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .offline: "Offline"
        case .notSetUp: "Not set up"
        case .unknown: "Not checked"
        }
    }
}

/// A folder's pairing with a Mac folder, while it's checked, asked or refused.
struct BoxPairing: Equatable {
    enum State: Equatable {
        /// The Mac folder, as shown.
        case checking(String)
        case ask(String, HostSync.Start, URL)
        case failed(String)
    }

    let place: BoxPlace
    let state: State

    var line: String {
        switch state {
        case .checking(let mac): "Checking \(mac)…"
        case .ask(let question, _, _): question
        case .failed(let why): why
        }
    }

    var failed: Bool { if case .failed = state { true } else { false } }
}

extension BoxList.Box {
    /// Its dot: connected while a window holds it online or it last answered, else what the last
    /// probe found.
    @MainActor var dotState: StatusDot.State {
        if HostConnection.live(alias)?.isOnline == true { return .connected }
        switch status {
        case .ready: return .connected
        case .notSetUp, .noGrant, .stale, .failed: return .notSetUp
        case .stopped, .unreachable: return .offline
        case .unknown, .probing, .working: return .unknown
        }
    }
}
