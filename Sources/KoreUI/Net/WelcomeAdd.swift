import AppKit
import HostClient
import SwiftUI

/// The Welcome switcher's "+" while this Mac is on a tailnet (frame D1): the tailnet's peers that
/// run kore-host and aren't this Mac's yet (probed when the list opens, at no other time), then
/// New box… and Use SSH… (the alias field, with its SSH config suggestions). Picking a peer
/// brings up its claim card.
struct WelcomeAddList: View {
    /// Use SSH…: the switcher's field.
    let useSSH: @MainActor () -> Void
    /// New box…: its popup.
    let newBox: @MainActor () -> Void
    /// A box claimed: the Welcome stands on it.
    let ready: @MainActor (String) -> Void
    @StateObject private var peers = Local<[ClaimPeer]>([])
    @StateObject private var refused = Local<[String: String]>([:])
    @StateObject private var lit = Local<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(peers.value) { peer in
                item(peer.id, glyph: .box, title: peer.name, detail: refused.value[peer.id] ?? "on your tailnet", story: StoryID.Net.welcomePeer(peer.name)) {
                    claim(peer)
                }
            }
            if !peers.value.isEmpty { Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs + 1) }
            item("new", glyph: nil, title: "New box…", detail: nil, story: StoryID.Net.newBox, action: newBox)
            item("ssh", glyph: nil, title: "Use SSH…", detail: nil, story: StoryID.Net.useSSH, action: useSSH)
        }
        .padding(.vertical, Space.xs + 1)
        .frame(width: Size.Net.listWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .task { peers.value = await Devices.shared.claims?.peers() ?? [] }
        .storyID(StoryID.Net.welcomeAdd)
    }

    private func item(_ id: String, glyph: NetGlyph.Kind?, title: String, detail: String?, story: StoryID, action: @escaping @MainActor () -> Void) -> some View {
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
            .background(lit.value == id ? Theme.Net.rowLit : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { lit.value = id } else if lit.value == id { lit.value = nil }
        }
        .storyID(story, press: action)
    }

    private func claim(_ peer: ClaimPeer) {
        Task { @MainActor in
            switch await WelcomeClaim.ask(peer, ready: ready) {
            case .some(let refusal): refused.value[peer.id] = refusal
            case nil: NetPopupHost.shared.close()
            }
        }
    }
}

/// A box's claim: its card (frame B, with the device code), then on Allow the box is this Mac's
/// and the Welcome stands on it.
@MainActor
enum WelcomeClaim {
    /// Nil once the card is up; else why the box can't be claimed from here.
    static func ask(_ peer: ClaimPeer, ready: @escaping @MainActor (String) -> Void) async -> String? {
        guard let claims = Devices.shared.claims else { return "Turn KoreNet on first" }
        switch await claims.claim(peer) {
        case .failure(let refusal): return refusal.line
        case .success(let info):
            DeviceCardPanel.show(info) { allow in
                guard allow else { return }
                Task { @MainActor in
                    if let key = await claims.allow(peer) {
                        Devices.shared.changed()
                        ready(key)
                    }
                }
            }
            return nil
        }
    }
}

/// New box… (frame D1 2): the one line to run on the box, Copy, and the wait for it. Opening it
/// opens the Add device window too, so its countdown is the same 10 minutes. A box that ran
/// `kore-host join` brings up its claim card.
struct NewBoxPopup: View {
    let ready: @MainActor (String) -> Void
    @StateObject private var copied = Local(false)
    @StateObject private var refusal = Local<String?>(nil)

    var body: some View {
        let picture = Devices.shared.picture()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                Text("New box").font(Theme.Net.line).fontWeight(.medium).foregroundStyle(Theme.text)
                if let until = picture.addUntil { Countdown(until: until) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xs)
            .frame(minHeight: Size.Net.header)
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
                if let refusal = refusal.value {
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
        .padding(.vertical, Space.xs + 1)
        .frame(width: Size.Net.sheetWidth - Space.md, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .task {
            Devices.shared.openAddWindow()
            guard let claims = Devices.shared.claims, let peer = await claims.newBox() else { return }
            if let why = await WelcomeClaim.ask(peer, ready: ready) { refusal.value = why } else { NetPopupHost.shared.close() }
        }
        .onDisappear { Devices.shared.claims?.cancel() }
        .storyID(StoryID.Net.newBoxPopup)
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
