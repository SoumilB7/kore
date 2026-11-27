import AppKit
import HostClient
import SwiftUI

/// What the Welcome's box view and the box popup share: a box's one line with its action, and the Add a
/// box… field.

/// A box's one line, and its action after a dot ("Stopped on mybox · Start"). Copy puts the
/// command in the pasteboard; Set up agents and Fix open the agents popup under the line (and
/// `opened` closes the popup it's in, one at a time); Show log opens a build's log; the rest are
/// the list's.
struct BoxNoteLine: View {
    let note: BoxList.Note
    let alias: String
    var opened: (() -> Void)?
    /// The list's actions (Kore: the box list; Devices: whatever adds its boxes).
    var act: @MainActor (BoxList.Action, String) async -> Void = { await BoxList.shared.act($0, on: $1) }
    /// Its action's storyline name, where a storyline presses it.
    var story: StoryID?
    @StateObject private var anchor = Held<NSView?>(nil)
    @StateObject private var copied = Local(false)

    var body: some View {
        Group {
            if note.more.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(note.line).foregroundStyle(Theme.tertiary).lineLimit(2).textSelection(.enabled)
                    if let action = note.action {
                        Text("·").foregroundStyle(Theme.tertiary)
                        button(action, story: story)
                    }
                }
            } else {
                // Several actions (Trust · Copy · Check again): the line whole (a fingerprint is
                // never cut), its actions under it.
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(note.line).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        if let action = note.action { button(action, story: story) }
                        ForEach(Array(note.more.enumerated()), id: \.offset) { _, more in
                            Text("·").foregroundStyle(Theme.tertiary)
                            button(more, story: (story ?? StoryID.Boxes.line).part(Self.part(more)))
                        }
                    }
                }
            }
        }
        .font(Chrome.caption)
        .background(BoxAnchor { anchor.value = $0 })
    }

    private func button(_ action: BoxList.Action, story: StoryID?) -> some View {
        let copies = if case .copy = action { true } else { false }
        return Button(copied.value && copies ? "Copied" : action.title) { take(action) }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .storyID(story, press: { take(action) })
    }

    private static func part(_ action: BoxList.Action) -> StoryID.Part {
        switch action {
        case .copy: .copy
        case .checkAgain, .tryAgain: .retry
        default: .use
        }
    }

    private func take(_ action: BoxList.Action) {
        switch action {
        case .copy(let command):
            StoryHost.pasteboard.clearContents()
            StoryHost.pasteboard.setString(command, forType: .string)
            copied.value = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied.value = false
            }
        case .setUpAgents, .differences:
            BoxCard.shared.showAgents(alias, under: anchor.value)
            opened?()
        case .showLog(let path):
            StoryHost.open(URL(fileURLWithPath: path))
        case .signIn(let page):
            if let url = URL(string: page) { StoryHost.open(url) }
        default:
            let act = act
            Task { await act(action, alias) }
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

/// A box's status (frame F): connected (filled, green), offline (filled, dim), not set up or
/// hasn't allowed this Mac (a ring), needs an update (filled accent: it needs you), not asked yet
/// (a faint ring).
struct StatusDot: View {
    enum State { case connected, offline, notSetUp, needsAllow, needsUpdate, unknown }
    let state: State

    var body: some View {
        let size = Size.statusPoint
        Group {
            switch state {
            case .connected: Circle().fill(Theme.success)
            case .offline: Circle().fill(Theme.tertiary)
            case .needsUpdate: Circle().fill(Theme.accent)
            case .notSetUp, .needsAllow: Circle().strokeBorder(Theme.tertiary, lineWidth: Stroke.hairline * 1.5)
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
        case .needsAllow: "Hasn't allowed this Mac"
        case .needsUpdate: "Needs an update"
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
        /// Another pair is in the way (the line names it): Unpair that first, then this Mac
        /// folder is checked again.
        case blocked(String, SyncPair, URL)
    }

    let place: BoxPlace
    let state: State

    var line: String {
        switch state {
        case .checking(let mac): "Checking \(mac)…"
        case .ask(let question, _, _): question
        case .failed(let why), .blocked(let why, _, _): why
        }
    }

    var failed: Bool {
        switch state {
        case .failed, .blocked: true
        default: false
        }
    }
}

extension BoxList.Box {
    /// Its dot: connected while a window holds it online or it last answered, else what the last
    /// probe found.
    @MainActor var dotState: StatusDot.State {
        if HostConnection.live(alias)?.isOnline == true { return older ? .needsUpdate : .connected }
        switch status {
        case .ready: return older ? .needsUpdate : .connected
        case .noGrant: return .needsAllow
        case .stale: return .needsUpdate
        case .notSetUp, .failed: return .notSetUp
        case .stopped, .unreachable: return .offline
        case .unknown, .probing, .working: return .unknown
        }
    }
}
