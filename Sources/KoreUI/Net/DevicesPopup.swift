import AppKit
import HostClient
import SwiftUI

/// The title row's network icon (frame A1), in the slot left of the clock. Quiet (secondary, no
/// dot) while every device is connected; at most one dot (pending → Tailscale off → offline);
/// dimmed while KoreNet is off, Tailscale is off, or this Mac isn't on a tailnet yet. Hover is the
/// one line behind the dot; a click opens Devices under it.
struct NetworkButton: View {
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var anchor = Held<NSView?>(nil)

    var body: some View {
        let look = Devices.shared.look()
        let open = DevicesPopup.openIn(anchor.value?.window)
        Button { DevicesPopup.toggle(under: anchor.value) } label: {
            NetGlyph(kind: .net, size: Size.Net.titleGlyph)
                .foregroundStyle(hovered.value || open ? Theme.text : look.dimmed ? Theme.Net.dim : Theme.Net.glyph)
                .frame(width: size, height: size)
                .background(hovered.value || open ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .bottomTrailing) {
                    if let dot = look.dot {
                        NetDot(fill: dot.fill, on: hovered.value || open ? Theme.surface : Theme.background).padding(Size.Net.dotInset)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .background(BoxAnchor { view in
            anchor.value = view
            DispatchQueue.main.async { NetAnchors.icon(view) }
        })
        .help(look.line)
        .accessibilityLabel(Text("Devices"))
        .accessibilityValue(Text(look.line))
        .storyID(StoryID.Net.icon) { DevicesPopup.toggle(under: anchor.value) }
    }
}

extension NetIconLook.Dot {
    var fill: NetDot.Fill {
        switch self {
        case .accent: .needsYou
        case .ring: .hollow
        case .dim: .offline
        }
    }
}

/// Devices (frame A2, C): this Mac, then each box and phone with its glyph, name, one detail and
/// dot; the devices waiting at a box; at most one line with at most one action. "+" opens the
/// Add device window; ⋯ (in the dot's place on hover) renames, takes offline or brings online,
/// joins an SSH box to KoreNet, and removes. Kore ▸ Devices… opens the same popup.
struct DevicesPopup: View {
    @StateObject private var hoveredRow = Local<String?>(nil)
    @StateObject private var renaming = Local<String?>(nil)
    @StateObject private var draft = Local("")
    @StateObject private var menuFor = Local<String?>(nil)
    @StateObject private var anchors = Held<[String: NSView]>([:])
    @FocusState private var renameFocused: Bool

    private var devices: Devices { .shared }

    var body: some View {
        let now = Date()
        let picture = devices.picture(now: now)
        VStack(alignment: .leading, spacing: 0) {
            header(picture, now: now)
            macRow(picture)
            ForEach(picture.devices) { row in deviceRow(row, now: now) }
            lines(picture, now: now)
        }
        .padding(.vertical, Space.xs + 1)
        .frame(width: Size.Net.popupWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onAppear {
            devices.net?.hold("devices", true)
            devices.net?.readStatus()
        }
        .onDisappear {
            devices.net?.hold("devices", false)
            devices.nudgeSeen()
        }
        .storyID(StoryID.Net.popup)
    }

    // MARK: Header

    private func header(_ picture: DevicesPicture, now: Date) -> some View {
        let adding = picture.addOpen(at: now)
        return HStack(spacing: Space.md) {
            Text(adding ? "Adding devices" : "Devices").font(Theme.Net.line).fontWeight(.medium).foregroundStyle(Theme.text)
            if adding, let until = picture.addUntil { Countdown(until: until) }
            Spacer(minLength: Space.md)
            Toggle("", isOn: Binding(get: { picture.net != .off }, set: { devices.setOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
                .help(picture.net == .off ? "KoreNet is off" : "KoreNet is on")
                .accessibilityLabel("KoreNet")
                .storyID(StoryID.Net.toggle, press: { devices.setOn(picture.net == .off) })
            if adding {
                NetHeaderButton(glyph: .close, lit: true, help: "Stop adding") { devices.closeAddWindow() }
                    .storyID(StoryID.Net.closeAdd, press: { devices.closeAddWindow() })
            } else if picture.net.adds {
                NetHeaderButton(glyph: .plus, lit: false, help: "Add device") { devices.openAddWindow() }
                    .storyID(StoryID.Net.add, press: { devices.openAddWindow() })
            }
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(minHeight: Size.Net.header)
    }

    // MARK: Rows

    private func macRow(_ picture: DevicesPicture) -> some View {
        NetRowFrame(lit: false) {
            NetGlyph(kind: .mac).foregroundStyle(Theme.Net.glyph)
            Text(picture.macName).font(Theme.Net.name).foregroundStyle(Theme.text).lineLimit(1)
            Text("this Mac").font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(picture.tailnetName.map { "On your tailnet as \($0)" } ?? "")
        .storyID(StoryID.Net.row("this-mac"))
    }

    private func deviceRow(_ row: DeviceRow, now: Date) -> some View {
        let dimmed = row.paused || row.needsTailscale || row.status != .connected && row.status != .unknown
        let lit = hoveredRow.value == row.id || menuFor.value == row.id
        let detail = DevicesWords.detail(row, now: now)
        return NetRowFrame(lit: lit) {
            NetGlyph(kind: row.kind.glyph).foregroundStyle(dimmed ? Theme.Net.dim : Theme.Net.glyph)
            if renaming.value == row.id {
                TextField("", text: $draft.value)
                    .textFieldStyle(.plain)
                    .font(Theme.Net.name)
                    .foregroundStyle(Theme.text)
                    .focused($renameFocused)
                    .frame(width: Size.Net.renameWidth)
                    .onSubmit {
                        devices.rename(row, to: draft.value)
                        renaming.value = nil
                    }
                    .onExitCommand { renaming.value = nil }
                    .onAppear { renameFocused = true }
                    .storyID(StoryID.Net.rename(row.id))
            } else {
                Text(row.name).font(Theme.Net.name).foregroundStyle(dimmed ? Theme.tertiary : Theme.text).lineLimit(1)
            }
            if let detail { Text(detail).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 0)
            if lit {
                NetMoreButton(lit: menuFor.value == row.id) { openMenu(row) }
                    .background(BoxAnchor { [anchors] view in anchors.value[row.id] = view })
                    .storyID(StoryID.Net.more(row.id), press: { openMenu(row) })
            } else if let dot = rowDot(row) {
                NetDot(fill: dot)
            }
        }
        .onHover { inside in
            if inside { hoveredRow.value = row.id } else if hoveredRow.value == row.id { hoveredRow.value = nil }
        }
        .help(DevicesWords.help(row) ?? "")
        .storyID(StoryID.Net.row(row.id))
        .background {
            // ⋯'s items, for storylines (a Kore menu's rows are found by index otherwise).
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.field)) { startRename(row) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.stop)) { devices.setPaused(row, true) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.reload)) { devices.setPaused(row, false) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.close)) { devices.remove(row) }
            if row.canJoin { Color.clear.storyAction(StoryID.Net.row(row.id).part(.use)) { join(row) } }
        }
    }

    private func rowDot(_ row: DeviceRow) -> NetDot.Fill? {
        if row.needsTailscale { return nil }
        if row.paused { return .offline }
        switch row.status {
        case .connected: return .connected
        case .offline: return .offline
        case .needsAllow, .stopped, .notSetUp: return .hollow
        case .needsUpdate: return .needsYou
        case .unknown: return nil
        }
    }

    private func openMenu(_ row: DeviceRow) {
        guard let view = anchors.value[row.id], let window = view.window else { return }
        let point = view.convert(CGPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY), to: nil)
        var items = [OptionItem("Rename") { startRename(row) }]
        items.append(row.paused ? OptionItem("Bring online") { devices.setPaused(row, false) } : OptionItem("Take offline") { devices.setPaused(row, true) })
        if row.canJoin { items.append(OptionItem("Join KoreNet") { join(row) }) }
        items.append(.rule)
        let forget = row.kind == .box && !row.canJoin && row.route == .ssh ? "Forget \(row.name) on this Mac" : "Remove \(row.name) from KoreNet"
        items.append(OptionItem("Remove", destructive: true, children: [OptionItem(forget, destructive: true) { devices.remove(row) }]))
        menuFor.value = row.id
        OptionsMenu.shared.show(items, at: point, in: window, source: "devices")
        Task { @MainActor in
            await Observed.until { !OptionsMenu.shared.isOpen }
            if menuFor.value == row.id { menuFor.value = nil }
        }
    }

    private func startRename(_ row: DeviceRow) {
        draft.value = row.name
        renaming.value = row.id
    }

    private func join(_ row: DeviceRow) {
        let anchor = NetAnchors.icon(in: NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow())
        NetPopupHost.shared.close()
        NetJoinSheet.show(row.id, under: anchor)
    }

    // MARK: Lines

    @ViewBuilder private func lines(_ picture: DevicesPicture, now: Date) -> some View {
        if !picture.pending.isEmpty {
            NetRule()
            Text("Waiting").font(Theme.Net.line).foregroundStyle(Theme.secondary)
                .padding(.horizontal, Space.xl)
                .frame(minHeight: Size.Net.subHeader)
            ForEach(picture.pending) { row in pendingRow(row, now: now) }
        }
        switch picture.net {
        case .off:
            NetLine { Text("KoreNet is off") }
        case .starting:
            NetLine { NetSpinner(); Text("Starting KoreNet") }
        case .notJoined:
            if picture.signingIn {
                NetLine {
                    NetSpinner()
                    Text("Finish signing in in your browser")
                    Text("·")
                    Button("Cancel") { devices.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .storyID(StoryID.Net.lineAction, press: { devices.cancelSignIn() })
                }
                .storyID(StoryID.Net.line)
            } else {
                NetAction(title: "Sign in to join your tailnet", glyph: .external, trailing: true) { devices.signIn() }
                    .help("Kore runs Tailscale inside the app")
                    .storyID(StoryID.Net.lineAction, press: { devices.signIn() })
            }
        case .stopped, .signedOut:
            NetRule()
            NetLine {
                Text(picture.net == .stopped ? "Tailscale is off on this Mac" : "Tailscale is signed out")
                Text("·")
                Button("Open Tailscale") { devices.openTailscale() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .storyID(StoryID.Net.lineAction, press: { devices.openTailscale() })
            }
            .storyID(StoryID.Net.line)
        case .unavailable(let why):
            NetRule()
            NetLine { Text("Kore's tailnet couldn't start") }.help(why).storyID(StoryID.Net.line)
        case .running:
            runningLines(picture, now: now)
        }
    }

    @ViewBuilder private func runningLines(_ picture: DevicesPicture, now: Date) -> some View {
        if picture.addOpen(at: now) {
            NetRule()
            NetLine { NetSpinner(); Text("On the phone or box, choose Join KoreNet") }
            ForEach(picture.refusals, id: \.name) { refusal in
                NetLine { Text(refusal.line) }.help(refusal.help)
            }
            NetAction(title: "Get the phone app", glyph: .external, trailing: false) { devices.getPhoneApp() }
                .storyID(StoryID.Net.phoneApp, press: { devices.getPhoneApp() })
        } else if picture.lockedOut {
            NetRule()
            NetLine { Text("This Mac waits for a Tailnet Lock signature") }
                .help("Sign it from a device that holds your lock key")
                .storyID(StoryID.Net.line)
        } else if let expiry = picture.macKeyExpiry, expiry.timeIntervalSince(now) < DevicesPicture.expirySoon {
            NetRule()
            NetLine {
                Text("This Mac's Tailscale key expires " + DevicesWords.expiresIn(expiry, now: now))
                Text("·")
                Button("Renew") { devices.renew() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .storyID(StoryID.Net.lineAction, press: { devices.renew() })
            }
            .storyID(StoryID.Net.line)
        } else if picture.devices.isEmpty && picture.pending.isEmpty {
            if picture.nudge {
                NetLine {
                    Text("On your tailnet")
                    Text("·")
                    Button("Add a device") { devices.openAddWindow() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .storyID(StoryID.Net.lineAction, press: { devices.openAddWindow() })
                }
                .storyID(StoryID.Net.line)
            } else {
                NetLine { Text("No other devices yet") }.storyID(StoryID.Net.line)
            }
        }
    }

    private func pendingRow(_ row: PendingRow, now: Date) -> some View {
        let lit = hoveredRow.value == "pending:" + row.id
        return Button { devices.ask(row) } label: {
            NetRowFrame(lit: lit) {
                NetGlyph(kind: row.kind.glyph).foregroundStyle(Theme.Net.glyph)
                Text(row.name).font(Theme.Net.name).foregroundStyle(Theme.text).lineLimit(1)
                Text(DevicesWords.waitingDetail(row, now: now)).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                NetGlyph(kind: .chevron, size: Size.Net.chevron).foregroundStyle(Theme.tertiary)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredRow.value = "pending:" + row.id } else if hoveredRow.value == "pending:" + row.id { hoveredRow.value = nil }
        }
        .storyID(StoryID.Net.pending(row.id), press: { devices.ask(row) })
    }

    // MARK: Showing

    /// Opens Devices under `anchor` (the icon), or closes it when it's open there.
    static func toggle(under anchor: NSView?) {
        if NetPopupHost.shared.isShowing("devices") {
            NetPopupHost.shared.close()
            return
        }
        guard let window = anchor?.window ?? NSApp.keyWindow else { return }
        show(in: window, under: anchor)
    }

    /// Kore ▸ Devices…: under the front window's icon, else at its top right.
    static func showFromMenu() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if NetPopupHost.shared.isShowing("devices") { return }
        show(in: window, under: NetAnchors.icon(in: window))
    }

    private static func show(in window: NSWindow, under anchor: NSView?) {
        Devices.shared.openedPopup()
        NetPopupHost.shared.show("devices", DevicesPopup(), in: window, under: anchor, edge: .trailing) { Devices.shared.closedPopup() }
    }

    static func openIn(_ window: NSWindow?) -> Bool {
        _ = Devices.shared.popupOpen
        return window != nil && NetPopupHost.shared.isShowing("devices")
    }
}

/// The popup's row: glyph, name, detail, then its dot or ⋯.
private struct NetRowFrame<Content: View>: View {
    let lit: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Space.md + 1) { content }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xxs + 1)
            .frame(maxWidth: .infinity, minHeight: Size.Net.row, alignment: .leading)
            .background(lit ? Theme.Net.rowLit : .clear)
            .contentShape(Rectangle())
    }
}

/// One tertiary line ("status · action").
private struct NetLine<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Space.sm) { content }
            .font(Theme.Net.line)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.xs + 1)
    }
}

/// An accent action row ("Get the phone app ↗", "Sign in to join your tailnet ↗").
private struct NetAction: View {
    let title: String
    let glyph: NetGlyph.Kind
    let trailing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                if !trailing { NetGlyph(kind: glyph, size: Size.Net.smallGlyph) }
                Text(title).font(Theme.Net.line)
                if trailing { NetGlyph(kind: glyph, size: Size.Net.smallGlyph) }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xxs + 1)
            .frame(maxWidth: .infinity, minHeight: Size.Net.line, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NetRule: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs + 1) }
}

/// The header's "+" and ×: 24pt, lit while it stands for something under way.
private struct NetHeaderButton: View {
    let glyph: NetGlyph.Kind
    let lit: Bool
    let help: String
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            NetGlyph(kind: glyph)
                .foregroundStyle(lit || hovered.value ? Theme.text : Theme.secondary)
                .frame(width: Size.Net.headerButton, height: Size.Net.headerButton)
                .background(lit || hovered.value ? Theme.Net.rowLit : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .popupAwareHelp(help)
        .accessibilityLabel(Text(help))
    }
}

/// A row's ⋯, in the dot's place on hover.
private struct NetMoreButton: View {
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NetGlyph(kind: .more)
                .foregroundStyle(lit ? Theme.text : Theme.secondary)
                .frame(width: Size.Net.more, height: Size.Net.more)
                .background(lit ? Theme.Net.moreLit : .clear, in: RoundedRectangle(cornerRadius: Radius.chip - 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -Space.sm)
        .accessibilityLabel(Text("More"))
    }
}

/// The Add device window's countdown, "9:42": the one clock, drawn only while it shows.
struct Countdown: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            Text("\(left / 60):" + String(format: "%02d", left % 60))
                .font(Theme.Net.line)
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .onChange(of: left == 0) { _, over in if over { Devices.shared.changed() } }
                .storyID(StoryID.Net.countdown)
        }
    }
}
