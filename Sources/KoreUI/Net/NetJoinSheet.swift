import AppKit
import HostClient
import SwiftUI

/// "mybox joins KoreNet" (frame D2): an SSH box joining KoreNet over its live SSH link. SSH
/// proves the box is the owner's, so no Allow card; the rows tick in order and the sheet closes
/// itself a second after the last, or stops on what needs an answer (no sudo, a sign-in, a
/// cancelled sign-in), or waits for Done once when the box is relayed. SSH stays as the fallback.
struct NetJoinSheet: View {
    let join: BoxNetJoin
    @StateObject private var key = Local("")
    @StateObject private var copied = Local(false)

    private var devices: Devices { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(join.name) joins KoreNet").font(Theme.Net.title).foregroundStyle(Theme.text).lineLimit(1)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.md)
            ForEach(Array(join.rows.enumerated()), id: \.offset) { _, row in check(row) }
            if let note = join.note {
                Text(note).font(Theme.Net.line).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.xs)
            }
            buttons
        }
        .padding(.top, Space.md)
        .padding(.bottom, Space.xl)
        .frame(width: Size.Net.sheetWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onChange(of: join.ending, initial: true) { _, ending in
            guard ending == .done else { return }
            Task { @MainActor in
                try? await Task.sleep(for: Size.Net.doneFor)
                if devices.joining === join { NetJoinSheet.close() }
            }
        }
        .storyID(StoryID.Net.sheet)
    }

    private func check(_ row: BoxNetJoin.Row) -> some View {
        HStack(spacing: Space.md + 1) {
            Group {
                switch row.mark {
                case .done: Text("✓").foregroundStyle(Theme.success)
                case .working: NetSpinner()
                case .attention: Text("●").foregroundStyle(Theme.warning)
                case .skipped: Text("–").foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: Size.Net.mark)
            Text(row.title).foregroundStyle(row.mark == .skipped ? Theme.tertiary : Theme.text).lineLimit(1)
            Spacer(minLength: Space.md)
            if let detail = row.detail {
                Text(detail).font(Theme.Net.detail).foregroundStyle(row.warns ? Theme.Net.warn : Theme.tertiary).lineLimit(1)
            }
        }
        .font(Theme.Net.name)
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xxs)
        .frame(minHeight: Size.Net.check)
    }

    @ViewBuilder private var buttons: some View {
        let runner = devices.joinRunnerNow
        HStack(spacing: Space.md) {
            Spacer(minLength: 0)
            switch join.ending {
            case .working:
                button("Cancel") { NetJoinSheet.close() }
            case .needsSudo:
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BoxNetJoin.sudoLine, forType: .string)
                    copied.value = true
                    Task { @MainActor in
                        try? await Task.sleep(for: Size.Net.copiedFor)
                        copied.value = false
                    }
                } label: {
                    HStack(spacing: Space.sm) {
                        NetGlyph(kind: .copy, size: Size.Net.smallGlyph)
                        Text(copied.value ? "Copied" : "Copy sudo line")
                    }
                }
                .buttonStyle(NetButtonStyle())
                .storyID(StoryID.Net.sheetButton("copy-sudo"))
                if runner?.offersKoreTailnet(join) == true {
                    button("Use Kore's tailnet", go: true) { runner?.useKoreTailnet(join) }
                } else {
                    button("Cancel") { NetJoinSheet.close() }
                }
            case .signIn:
                button("Use an auth key…") { join.askAuthKey() }
                Button { runner?.signIn(join) } label: {
                    HStack(spacing: Space.sm) {
                        Text("Sign in")
                        NetGlyph(kind: .external, size: Size.Net.chevron)
                    }
                }
                .buttonStyle(NetButtonStyle(look: .go))
                .storyID(StoryID.Net.sheetButton("sign-in"), press: { runner?.signIn(join) })
            case .authKey:
                TextField("", text: $key.value, prompt: Text("tskey-auth-…").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Net.monoSmall)
                    .fieldWell(focused: true)
                    .onSubmit { runner?.authKey(join, key.value) }
                button("Join", go: true) { runner?.authKey(join, key.value) }
            case .signInCancelled:
                button("Stay on SSH") {
                    runner?.stayOnSSH(join)
                    NetJoinSheet.close()
                }
                button("Try again", go: true) { runner?.start(join) }
            case .relayed:
                button("Done", go: true) { NetJoinSheet.close() }
            case .done:
                EmptyView()
            case .unreachable, .failed:
                button("Close", go: true) { NetJoinSheet.close() }
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, join.ending == .done ? 0 : Space.xl)
    }

    private func button(_ title: String, go: Bool = false, action: @escaping @MainActor () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(NetButtonStyle(look: go ? .go : .plain))
            .storyID(StoryID.Net.sheetButton(title.lowercased().replacingOccurrences(of: " ", with: "-")), press: action)
    }

    // MARK: Showing

    /// Starts `key`'s join and shows its sheet under `anchor` (the Welcome's line, or the icon).
    static func show(_ key: String, under anchor: NSView?, in window: NSWindow? = nil) {
        Devices.shared.join(key)
        guard let join = Devices.shared.joining, let window = anchor?.window ?? window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NetPopupHost.shared.show("join", NetJoinSheet(join: join), in: window, under: anchor, edge: .center, modal: true) { Devices.shared.endJoin() }
    }

    static func close() {
        if NetPopupHost.shared.isShowing("join") { NetPopupHost.shared.close() } else { Devices.shared.endJoin() }
    }
}

/// A box's Welcome line for KoreNet: "Runs over SSH · Join KoreNet" while it could join and
/// nothing else claims the slot, or "Can't reach Tailscale · stays on SSH" after a join that
/// couldn't.
struct NetJoinLine: View {
    let alias: String
    @StateObject private var anchor = Held<NSView?>(nil)

    static func shows(_ alias: String) -> Bool {
        if BoxNetJoin.unreachable.contains(alias) { return true }
        return Devices.shared.picture().devices.first { $0.id == alias }.map { $0.canJoin && $0.status == .connected && $0.route == .ssh } ?? false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if BoxNetJoin.unreachable.contains(alias) {
                Text("Can't reach Tailscale · stays on SSH").foregroundStyle(Theme.tertiary)
            } else {
                Text("Runs over SSH").foregroundStyle(Theme.tertiary)
                Text("·").foregroundStyle(Theme.tertiary)
                Button("Join KoreNet") { NetJoinSheet.show(alias, under: anchor.value) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .storyID(StoryID.Net.joinLine, press: { NetJoinSheet.show(alias, under: anchor.value) })
            }
        }
        .font(Chrome.caption)
        .background(BoxAnchor { anchor.value = $0 })
    }
}

extension Devices {
    /// A box's join sheet in `window`, under its network icon (storylines; Kore opens it from
    /// Devices ⋯ and the Welcome's line).
    package func openJoin(_ key: String, in window: NSWindow?) {
        NetJoinSheet.show(key, under: window.flatMap { NetAnchors.icon(in: $0) }, in: window)
    }
}
