import AppKit
import HostClient
import Observation
import SwiftUI

// Adding a box, wherever it's asked for: the Devices popup's "Add a box" and the Welcome
// switcher's "+". One set of choices and one set of pieces, so the two never drift: the
// kore-host boxes found on the tailnet (KoreNet on), Use SSH… (the alias field with the SSH
// config's hosts, then the box's set-up line), and New box… (only while the latest release
// carries `kore-host.sh`: never a dead line).

/// What adding a box offers now.
package struct BoxAddChoices: Equatable, Sendable {
    /// Tailnet peers that run kore-host and aren't this Mac's yet (KoreNet on only).
    package var found: [ClaimPeer]
    /// New box…: the release's install line, then `kore-host join` and its claim.
    package var newBox: Bool
    /// Use SSH…: always (it works with KoreNet off, and pushes this Mac's own kore-host).
    package var ssh: Bool { true }

    package init(found: [ClaimPeer] = [], newBox: Bool = false) {
        self.found = found
        self.newBox = newBox
    }

    /// `release`: the latest release has `kore-host.sh` (nil: not known yet, so not offered).
    package static func make(net: DevicesPicture.Net, found: [ClaimPeer], release: Bool?) -> BoxAddChoices {
        BoxAddChoices(found: net == .running ? found : [], newBox: release == true)
    }

    /// Only Use SSH… to offer: the field opens at once.
    package var sshOnly: Bool { found.isEmpty && !newBox }
}

/// Whether the latest release carries `kore-host.sh` (New box…'s install line): asked once, when
/// the add-box choices first open, and kept for the run. Offline, it isn't kept: the next opening
/// asks again. Never on a timer.
@MainActor @Observable
package final class HostRelease {
    package static let shared = HostRelease()

    /// Nil until GitHub has answered.
    package private(set) var hasScript: Bool?
    /// GitHub's answer for the latest release: its status and body; nil when it didn't answer
    /// (storylines: never asked unless a storyline says what to answer).
    @ObservationIgnored package var fetch: @Sendable () async -> (status: Int, data: Data)?
    @ObservationIgnored private var asking: Task<Void, Never>?

    nonisolated package static let latest = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
    nonisolated package static let script = "kore-host.sh"

    package init(fetch: (@Sendable () async -> (status: Int, data: Data)?)? = nil) {
        let story = StorylineSeams.backend != nil
        self.fetch = fetch ?? { story ? nil : await Self.ask() }
    }

    /// Asks once a run (a check under way is the one waited on).
    package func check() async {
        if hasScript != nil { return }
        if let asking { return await asking.value }
        let fetch = fetch
        let task = Task { @MainActor in
            guard let answer = await fetch() else { return }
            hasScript = Self.hasScript(status: answer.status, data: answer.data)
        }
        asking = task
        await task.value
        asking = nil
    }

    /// Forgets the answer (tests, storylines).
    package func forget() { hasScript = nil }

    /// 200: whether its assets name `kore-host.sh`; 404 (no release yet): false; else unknown.
    nonisolated package static func hasScript(status: Int, data: Data) -> Bool? {
        switch status {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let assets = json["assets"] as? [[String: Any]] ?? []
            return assets.contains { $0["name"] as? String == script }
        case 404: return false
        default: return nil
        }
    }

    nonisolated private static func ask() async -> (status: Int, data: Data)? {
        var request = URLRequest(url: latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

/// The box list as adding a box uses it (Kore: `BoxList`; storylines: a script): the SSH config's
/// hosts, listing a box and asking it once, its one line and that line's action.
@MainActor
package protocol BoxAdding: AnyObject {
    func suggestions(_ typed: String) -> [String]
    /// Listed from now on (its Devices row, its Welcome chip), then asked about once.
    func addBox(_ alias: String)
    func note(_ alias: String) -> BoxList.Note?
    func act(_ action: BoxFix, on alias: String) async
}

extension BoxList: BoxAdding {
    package func addBox(_ alias: String) {
        guard let alias = Self.alias(alias) else { return }
        add(alias)
        Task { await probe(alias) }
    }

    package func note(_ alias: String) -> Note? { box(alias)?.note }
}

/// The choices, as rows: the boxes found on the tailnet (probed as the rows show, at no other
/// time), then Use SSH… and New box…. Picking a found box brings up its claim card.
struct BoxAddChoicesList: View {
    let net: DevicesPicture.Net
    let useSSH: @MainActor () -> Void
    let newBox: @MainActor () -> Void
    /// A box claimed: its key.
    let ready: @MainActor (String) -> Void
    /// Its claim card came up.
    var asked: @MainActor () -> Void = {}
    @StateObject private var peers = Local<[ClaimPeer]>([])
    @StateObject private var refused = Local<[String: String]>([:])

    var body: some View {
        let choices = BoxAddChoices.make(net: net, found: peers.value, release: HostRelease.shared.hasScript)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(choices.found) { peer in
                BoxAddRow(glyph: .box, title: peer.name, detail: refused.value[peer.id] ?? "on your tailnet", story: StoryID.Net.welcomePeer(peer.name)) {
                    claim(peer)
                }
            }
            if !choices.found.isEmpty { Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs + 1) }
            BoxAddRow(glyph: nil, title: "Use SSH…", detail: nil, story: StoryID.Net.useSSH, action: useSSH)
            if choices.newBox {
                BoxAddRow(glyph: nil, title: "New box…", detail: nil, story: StoryID.Net.newBox, action: newBox)
            }
        }
        .task(id: net == .running) {
            async let release: Void = HostRelease.shared.check()
            if net == .running { peers.value = await Devices.shared.claims?.peers() ?? [] }
            await release
        }
    }

    private func claim(_ peer: ClaimPeer) {
        Task { @MainActor in
            switch await WelcomeClaim.ask(peer, ready: ready) {
            case .some(let refusal): refused.value[peer.id] = refusal
            case nil: asked()
            }
        }
    }
}

/// One choice: its glyph column, title and quiet detail, lit under the pointer.
struct BoxAddRow: View {
    let glyph: NetGlyph.Kind?
    let title: String
    let detail: String?
    let story: StoryID
    let action: @MainActor () -> Void
    @StateObject private var lit = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Group { if let glyph { NetGlyph(kind: glyph).foregroundStyle(Theme.Net.glyph) } else { Color.clear } }
                    .frame(width: Size.Net.mark, height: Size.Net.mark)
                Text(title).font(Theme.Net.name).foregroundStyle(Theme.text).lineLimit(1)
                if let detail { Text(detail).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xxs + 1)
            .frame(maxWidth: .infinity, minHeight: Size.Net.line, alignment: .leading)
            .background(lit.value ? Theme.Net.rowLit : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { lit.value = $0 }
        .storyID(story, press: action)
    }
}

/// Use SSH…: the alias field, and up to five SSH config hosts that match what's typed (plain
/// aliases, never a node's id). Return or a host adds it; Esc gives up.
struct BoxAliasEntry: View {
    @Binding var text: String
    let story: StoryID
    let suggestions: [String]
    let add: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoxAliasField(text: $text, add: add, cancel: cancel)
                .storyID(story)
            ForEach(suggestions.prefix(5), id: \.self) { host in
                Button { add(host) } label: {
                    Text(host).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                        .padding(.horizontal, Space.sm)
                        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .storyID(StoryID.Net.boxHost(host), press: { add(host) })
            }
        }
    }
}

/// New box…'s body: the one line to run on the box, Copy, and the wait for it. Waiting opens the
/// Add device window too, so its countdown is the same 10 minutes; a box that ran `kore-host join`
/// brings up its claim card. KoreNet off: the line, and "KoreNet is off · Turn on" in the wait's
/// place (a claim needs the tailnet).
struct NewBoxBody: View {
    let ready: @MainActor (String) -> Void
    /// The claim card came up.
    let asked: @MainActor () -> Void
    @StateObject private var copied = Local(false)
    @StateObject private var refusal = Local<String?>(nil)

    var body: some View {
        let on = Devices.shared.picture().net == .running
        VStack(alignment: .leading, spacing: 0) {
            Text("Run this on the box:").font(Theme.Net.line).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xs)
            HStack(spacing: Space.md) {
                Text(Devices.installLine).font(Theme.Net.monoSmall).foregroundStyle(Theme.Net.monoText).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(action: copy) {
                    HStack(spacing: Space.sm) {
                        NetGlyph(kind: .copy, size: Size.Net.smallGlyph)
                        Text(copied.value ? "Copied" : "Copy")
                    }
                }
                .buttonStyle(NetButtonStyle(height: Size.Net.smallButton))
                .storyID(StoryID.Net.copyInstall, press: copy)
            }
            .padding(.leading, Space.md + 1)
            .padding(.trailing, Space.sm)
            .padding(.vertical, Space.sm)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xxs)
            .padding(.bottom, Space.sm)
            HStack(spacing: Space.sm) {
                if !on {
                    Text("KoreNet is off")
                    Text("·")
                    Button("Turn on") { Devices.shared.setOn(true) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else if let refusal = refusal.value {
                    Text(refusal)
                } else {
                    NetSpinner()
                    Text("Waiting for the box")
                }
            }
            .font(Theme.Net.line)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.xs + 1)
        }
        .task(id: on) {
            guard on else { return }
            Devices.shared.openAddWindow()
            guard let claims = Devices.shared.claims, let peer = await claims.newBox() else { return }
            if let why = await WelcomeClaim.ask(peer, ready: ready) { refusal.value = why } else { asked() }
        }
        .onDisappear { Devices.shared.claims?.cancel() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Devices.installLine, forType: .string)
        copied.value = true
        Task { @MainActor in
            try? await Task.sleep(for: Size.Net.copiedFor)
            copied.value = false
        }
    }
}
