import AppKit
import HostClient
import SwiftUI

/// The title row's network icon (frame A1), in the slot left of the clock. Quiet (secondary, no
/// dot) while every device is connected; at most one dot (pending → Tailscale off → offline);
/// dimmed while KoreNet is off, Tailscale is off, or this Mac isn't on a tailnet yet. Hover is the
/// one line behind the dot; a click opens or closes the window's Devices pane (`DevicesSidebar`),
/// or Devices under it where there's no pane (the Welcome).
struct NetworkButton: View {
    let size: CGFloat
    /// The window's Devices pane: open (the icon stays lit) and its toggle. Nil: the popup.
    var pane: (open: Bool, toggle: @MainActor () -> Void)?
    @StateObject private var hovered = Local(false)
    @StateObject private var anchor = Held<NSView?>(nil)

    var body: some View {
        let look = Devices.shared.look()
        let open = pane?.open ?? DevicesPopup.openIn(anchor.value?.window)
        Button(action: press) {
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
        .storyID(StoryID.Net.icon, press: press)
    }

    private func press() {
        if let pane { pane.toggle() } else { DevicesPopup.toggle(under: anchor.value) }
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
/// joins an SSH box to KoreNet, and removes. A folder window shows the same list as its trailing
/// pane (`DevicesSidebar`); the Welcome, and Kore ▸ Devices… with no folder window, the popup.
struct DevicesPopup: View {
    /// As a window's trailing pane (`DevicesSidebar`) rather than a popup.
    var pane = false
    /// The KoreNet bus hold's key while it shows.
    var holdKey = "devices"
    @StateObject private var hoveredRow = Local<String?>(nil)
    @StateObject private var renaming = Local<String?>(nil)
    @StateObject private var draft = Local("")
    @StateObject private var menuFor = Local<String?>(nil)
    @StateObject private var anchors = Held<[String: NSView]>([:])
    /// "Add a box", one step at a time: its choices, the alias field, New box…, or the box just
    /// added (its set-up line). Nil: just the row.
    @StateObject private var addingBox = Local<AddBoxStep?>(nil)
    @FocusState private var renameFocused: Bool

    private var devices: Devices { .shared }

    enum AddBoxStep: Equatable {
        case choices
        case ssh(String)
        case newBox
        case added(String)
    }

    var body: some View {
        let now = Date()
        let picture = devices.picture(now: now)
        devicesFrame(picture, now: now)
        .onAppear {
            DevicesSidebar.hold(holdKey, by: 1)
            if pane { devices.openedPane() }
            devices.net?.readStatus()
            Task { await devices.readLock() }
        }
        .onDisappear {
            DevicesSidebar.hold(holdKey, by: -1)
            if pane { devices.closedPane() }
            devices.nudgeSeen()
        }
        .storyID(pane ? StoryID.Net.panel : StoryID.Net.popup)
    }

    /// The popup: as tall as its rows; taller than the room under the icon, they scroll. The pane
    /// fills its column on the window's ground, its rows scrolling under the header.
    @ViewBuilder
    private func devicesFrame(_ picture: DevicesPicture, now: Date) -> some View {
        if pane {
            VStack(alignment: .leading, spacing: 0) {
                header(picture, now: now)
                ScrollView(.vertical) { rows(picture, now: now).padding(.bottom, Space.xs + 1) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header(picture, now: now)
                    rows(picture, now: now)
                }
                .padding(.vertical, Space.xs + 1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: NetPopupRoom.shared.height)
            .frame(width: Size.Net.popupWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .panel(.panel)
            .cornerMarks(Theme.cornerOption)
            .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        }
    }

    private func rows(_ picture: DevicesPicture, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            macRow(picture)
            ForEach(picture.devices) { row in deviceRow(row, now: now) }
            if picture.devices.contains(where: { $0.kind == .box }) { keepBoxesRow }
            lines(picture, now: now)
            addBox(picture)
        }
    }

    // MARK: Header

    private func header(_ picture: DevicesPicture, now: Date) -> some View {
        let adding = picture.addOpen(at: now)
        return HStack(spacing: Space.md) {
            Text(adding ? "Adding devices" : "Devices").font(Theme.Net.line).fontWeight(.medium).foregroundStyle(Theme.text)
            if adding, let until = picture.addUntil { Countdown(until: until) }
            Spacer(minLength: Space.md)
            // While adding, the header is the window's (mockup C): its countdown and ×.
            if !adding {
                Toggle("", isOn: Binding(get: { picture.net != .off }, set: { devices.setOn($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .help(picture.net == .off ? "KoreNet is off" : "KoreNet is on")
                    .accessibilityLabel("KoreNet")
                    .storyID(StoryID.Net.toggle, press: { devices.setOn(picture.net == .off) })
            }
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
        .frame(minHeight: pane ? Layout.Explorer.header : Size.Net.header)
    }

    // MARK: Rows

    /// "Keep boxes updated": one quiet line with its switch, while there are boxes.
    private var keepBoxesRow: some View {
        @Bindable var updates = BoxUpdates.shared
        return NetLine {
            Text("Keep boxes updated")
            Spacer(minLength: Space.md)
            Toggle("", isOn: $updates.keep)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Keep boxes updated")
                .storyID(StoryID.Net.keepBoxes, press: { updates.keep.toggle() })
        }
    }

    private func macRow(_ picture: DevicesPicture) -> some View {
        NetRowFrame(lit: false) {
            NetGlyph(kind: .mac).foregroundStyle(Theme.Net.glyph)
            Text(picture.macName).font(Theme.Net.name).foregroundStyle(Theme.text).lineLimit(1)
            Text(DevicesWords.macDetail(picture)).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(DevicesWords.macHelp(picture))
        .storyID(StoryID.Net.row("this-mac"))
    }

    private func deviceRow(_ row: DeviceRow, now: Date) -> some View {
        // Dimmed when it can't be reached; one that only needs an update is still there.
        let dimmed = row.paused || row.needsTailscale || row.status != .connected && row.status != .unknown && row.status != .needsUpdate
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
                    .accessibilityLabel(Text("Name"))
                    .storyID(StoryID.Net.rename(row.id))
            } else {
                Text(row.name).font(Theme.Net.name).foregroundStyle(dimmed ? Theme.tertiary : Theme.text).lineLimit(1).layoutPriority(1)
            }
            if let detail { Text(detail).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 0)
            if lit {
                NetMoreButton(lit: menuFor.value == row.id, name: row.name) { openMenu(row) }
                    .background(BoxAnchor { [anchors] view in anchors.value[row.id] = view })
            } else if let dot = rowDot(row) {
                NetDot(fill: dot)
            }
        }
        .onHover { inside in
            if inside { hoveredRow.value = row.id } else if hoveredRow.value == row.id { hoveredRow.value = nil }
        }
        .help(DevicesWords.help(row) ?? "")
        .background(BoxAnchor { [anchors] view in anchors.value["row:" + row.id] = view })
        .storyID(StoryID.Net.row(row.id))
        .background {
            // ⋯ shows on hover only: storylines open its menu without one.
            Color.clear.storyAction(StoryID.Net.more(row.id)) { openMenu(row) }
            // ⋯'s items, for storylines (a Kore menu's rows are found by index otherwise).
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.field)) { startRename(row) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.stop)) { devices.setPaused(row, true) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.reload)) { devices.setPaused(row, false) }
            Color.clear.storyAction(StoryID.Net.row(row.id).part(.close)) { devices.remove(row) }
            if row.canJoin { Color.clear.storyAction(StoryID.Net.row(row.id).part(.use)) { join(row) } }
            if let page = row.ownPage, let url = URL(string: page) { Color.clear.storyAction(StoryID.Net.row(row.id).part(.signIn)) { devices.openURL(url) } }
        }
    }

    private func rowDot(_ row: DeviceRow) -> NetDot.Fill? {
        if row.needsTailscale { return nil }
        if row.paused { return .offline }
        if let own = row.own, !own.signedIn, row.status != .offline { return .needsYou }
        switch row.status {
        case .connected: return .connected
        case .offline: return .offline
        case .needsAllow, .stopped, .notSetUp: return .hollow
        case .needsUpdate: return .needsYou
        case .unknown: return nil
        }
    }

    private func openMenu(_ row: DeviceRow) {
        // Under ⋯, or (opened without the pointer) at the row's trailing end.
        let more = anchors.value[row.id].flatMap { $0.window == nil ? nil : $0 }
        guard let view = more ?? anchors.value["row:" + row.id], let window = view.window else { return }
        let x = more == nil ? view.bounds.maxX - Size.Net.more : view.bounds.minX
        let point = view.convert(CGPoint(x: x, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY), to: nil)
        // Another of the owner's Macs: Remove only (it pairs again from its Add device window).
        var items = row.kind == .mac ? [] : [OptionItem("Rename") { startRename(row) }]
        if row.kind != .mac {
            items.append(row.paused ? OptionItem("Bring online") { devices.setPaused(row, false) } : OptionItem("Take offline") { devices.setPaused(row, true) })
        }
        // A linked phone's own log, to debug it without a cable.
        if row.kind == .phone, row.status == .connected { items.append(OptionItem("Get logs") { devices.fetchLogs(row) }) }
        if row.canJoin { items.append(OptionItem(row.upgradeNote == nil ? "Join KoreNet" : "Try again") { join(row) }) }
        // Kore's tailnet there signed out: its page opens here (the box's own, for this account).
        if let page = row.ownPage, let url = URL(string: page) {
            items.append(OptionItem("Sign in ↗") { devices.openURL(url) })
        } else if let own = row.own, !own.signedIn, row.koreTailnet, row.upgradeFix != .relogin {
            items.append(OptionItem("Sign in ↗") { devices.relogin(row) })
        }
        // A stopped upgrade's one action (its line is the row's detail).
        switch row.upgradeFix {
        case .copy(let line)?:
            items.append(OptionItem(line == BoxNetJoin.sudoLine ? "Copy sudo line" : "Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            })
        case .signIn(let page)?:
            if let url = URL(string: page) { items.append(OptionItem("Sign in ↗") { devices.openURL(url) }) }
        case .relogin?:
            items.append(OptionItem(BoxFix.relogin.title) { devices.relogin(row) })
        case .tryAgain? where !row.canJoin:
            items.append(OptionItem("Try again") { join(row) })
        case .update?, .setUp?:
            let fix = row.upgradeFix!
            items.append(OptionItem(fix.title) { Task { await BoxList.shared.act(fix, on: row.id) } })
        default:
            break
        }
        // The SSH route it was set up by, while the tailnet carries it: only when asked.
        if devices.canForgetSSH(row), let ssh = row.ssh {
            items.append(OptionItem("Forget this SSH route", children: [OptionItem("Forget \(NodeDirectory.sshRoute(ssh))") { devices.forgetSSH(row) }]))
        }
        if !items.isEmpty { items.append(.rule) }
        let forget = DevicesWords.remove(row.name, kind: row.kind, enrolled: row.enrolled)
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
        let window = NetPopupHost.shared.window ?? anchors.value["row:" + row.id]?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let anchor = window.flatMap { NetAnchors.icon(in: $0) }
        NetPopupHost.shared.close()
        NetJoinSheet.show(row.id, under: anchor, in: window)
    }

    // MARK: Lines

    @ViewBuilder private func lines(_ picture: DevicesPicture, now: Date) -> some View {
        let signatures = picture.net == .running ? devices.signatures : []
        if !picture.pending.isEmpty || !signatures.isEmpty {
            NetRule()
            Text("Waiting").font(Theme.Net.line).foregroundStyle(Theme.secondary)
                .padding(.horizontal, Space.xl)
                .frame(minHeight: Size.Net.subHeader)
            ForEach(picture.pending) { row in pendingRow(row, now: now) }
            ForEach(signatures) { row in signatureRow(row) }
        }
        // Tailscale carries the links now and Kore's own hasn't signed in: one line until it has.
        if picture.ownSignIn, picture.net == .running {
            NetRule()
            signInLine(picture)
        }
        switch picture.net {
        case .off:
            NetLine { Text("KoreNet is off") }
        case .starting:
            NetLine { NetSpinner(); Text("Starting KoreNet") }
        case .notJoined:
            signInLine(picture)
        case .stopped, .signedOut:
            NetRule()
            NetLine {
                Text(picture.net == .stopped ? "Tailscale is off on this Mac" : "Tailscale is signed out")
                Text("·")
                Button("Open Tailscale") { devices.openTailscale() }.buttonStyle(.plain).foregroundStyle(Theme.accent).netHit()
                    .storyID(StoryID.Net.lineAction, press: { devices.openTailscale() })
            }
            .storyID(StoryID.Net.line)
        case .unavailable(let why):
            let action = Devices.unavailable(why)
            NetRule()
            NetLine {
                Text("Kore's tailnet couldn't start")
                Text("·")
                Button { devices.unavailableAction(why) } label: {
                    HStack(spacing: Space.xs) {
                        Text(action.title)
                        if action == .installTailscale { NetGlyph(kind: .external, size: Size.Net.smallGlyph) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).netHit()
                .storyID(StoryID.Net.lineAction, press: { devices.unavailableAction(why) })
            }
            .help(why)
            .storyID(StoryID.Net.line)
        case .running:
            runningLines(picture, now: now)
        }
    }

    @ViewBuilder private func runningLines(_ picture: DevicesPicture, now: Date) -> some View {
        if let note = devices.logsNote { NetLine { Text(note) } }
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
                Button("Renew") { devices.renew() }.buttonStyle(.plain).foregroundStyle(Theme.accent).netHit()
                    .storyID(StoryID.Net.lineAction, press: { devices.renew() })
            }
            .storyID(StoryID.Net.line)
        } else if picture.devices.isEmpty && picture.pending.isEmpty {
            if picture.nudge {
                NetLine {
                    Text("On your tailnet")
                    Text("·")
                    Button("Add a device") { devices.openAddWindow() }.buttonStyle(.plain).foregroundStyle(Theme.accent).netHit()
                        .storyID(StoryID.Net.lineAction, press: { devices.openAddWindow() })
                }
                .storyID(StoryID.Net.line)
            } else {
                NetLine { Text("No other devices yet") }.storyID(StoryID.Net.line)
            }
        }
    }

    // MARK: Add a box

    /// "Add a box", whatever KoreNet's state (an SSH box needs none of it): one click opens its
    /// choices under it (`BoxAddChoicesList`, the Welcome "+"'s too), a second closes them.
    @ViewBuilder private func addBox(_ picture: DevicesPicture) -> some View {
        NetAction(title: "Add a box", glyph: .plus, trailing: false) { toggleAddBox() }
            .storyID(StoryID.Net.addBox, press: { toggleAddBox() })
        switch addingBox.value {
        case nil:
            EmptyView()
        case .choices:
            BoxAddChoicesList(net: picture.net, useSSH: { addingBox.value = .ssh("") }, newBox: { addingBox.value = .newBox }, ready: boxReady) {
                addingBox.value = nil
            }
        case .ssh(let text):
            BoxAliasEntry(
                text: Binding(get: { text }, set: { typed in if case .ssh = addingBox.value { addingBox.value = .ssh(typed) } }),
                story: StoryID.Net.boxField, suggestions: devices.adder.suggestions(text), add: addAlias
            ) { addingBox.value = .choices }
            .padding(.horizontal, Space.xl - Space.xs)
            .padding(.vertical, Space.xxs)
        case .newBox:
            NewBoxBody(ready: boxReady) { addingBox.value = nil }
        case .added(let alias):
            // The box's own line while it's asked about and set up: Set up, each step, Ready.
            if let note = devices.adder.note(alias) {
                BoxNoteLine(note: note, alias: alias, opened: { NetPopupHost.shared.close() }, act: { await Devices.shared.adder.act($0, on: $1) }, story: StoryID.Net.boxLineAction)
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.xs + 1)
                    .storyID(StoryID.Net.boxLine)
            }
        }
    }

    private func toggleAddBox() {
        addingBox.value = addingBox.value == nil ? .choices : nil
    }

    /// Use SSH…'s alias: listed now (its row above, its Welcome chip), asked once; its line
    /// shows here in the field's place.
    private func addAlias(_ typed: String) {
        guard let alias = BoxList.alias(typed) else { return }
        addingBox.value = .added(alias)
        devices.adder.addBox(alias)
        devices.changed()
    }

    /// A box claimed (a tailnet box, or New box…'s): listed like any other.
    private func boxReady(_ key: String) {
        devices.adder.addBox(key)
        devices.changed()
        addingBox.value = nil
    }

    /// Kore's own tailnet's sign-in: its page, or "finish in the browser" while it's open.
    @ViewBuilder private func signInLine(_ picture: DevicesPicture) -> some View {
        if picture.signingIn {
            NetLine {
                NetSpinner()
                Text("Finish signing in in the browser")
                Text("·")
                Button("Cancel") { devices.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(Theme.accent).netHit()
                    .storyID(StoryID.Net.lineAction, press: { devices.cancelSignIn() })
            }
            .storyID(StoryID.Net.line)
        } else {
            // Its sign-in went with the key change (0.3.7): that's the line until it's signed in again.
            NetAction(title: KoreNetSwitch.shared?.signInAgainNote ?? DevicesWords.signIn, glyph: .external, trailing: true) { devices.signIn() }
                .help("Kore's own tailnet, inside the app")
                .storyID(StoryID.Net.lineAction, press: { devices.signIn() })
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

    /// A node Tailnet Lock keeps out: "needs a signature", and Sign when this Mac may sign it.
    private func signatureRow(_ row: SignatureRow) -> some View {
        let signing = devices.signing.contains(row.nodeKey)
        let failed = devices.signFailed.contains(row.nodeKey)
        return NetRowFrame(lit: false) {
            NetGlyph(kind: row.phone ? .phone : .box).foregroundStyle(Theme.Net.glyph)
            Text(row.name).font(Theme.Net.name).foregroundStyle(Theme.text).lineLimit(1)
            Text(failed ? "couldn't sign · try again" : SignatureRow.detail).font(Theme.Net.detail).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            if signing {
                NetSpinner()
            } else if row.canSign {
                Button(SignatureRow.sign) { Task { await devices.sign(row) } }.buttonStyle(.plain).font(Theme.Net.line).foregroundStyle(Theme.accent)
                    .storyID(StoryID.Net.sign(row.nodeKey), press: { Task { await devices.sign(row) } })
            }
        }
        .help(row.canSign ? "" : SignatureRow.help)
        .storyID(StoryID.Net.pending(row.nodeKey))
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
        NetPopupHost.shared.show("devices", DevicesPopup(), in: window, under: anchor, edge: edge(of: anchor, in: window)) { Devices.shared.closedPopup() }
    }

    /// Which of the icon's edges the popup lines up with: its leading one where the icon sits in
    /// the window's left half (the Welcome's, after the traffic lights), else its trailing one (a
    /// folder window's, by the clock), so the popup opens into the window.
    static func edge(of anchor: NSView?, in window: NSWindow) -> NetPopupHost.Edge {
        guard let anchor, anchor.window === window, let content = window.contentView else { return .trailing }
        return content.convert(anchor.bounds, from: anchor).midX < content.bounds.midX ? .leading : .trailing
    }

    static func openIn(_ window: NSWindow?) -> Bool {
        _ = Devices.shared.popupOpen
        // Lit in the window it shows in only (the Welcome and a folder window each have an icon).
        return window != nil && NetPopupHost.shared.isShowing("devices") && NetPopupHost.shared.window === window
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

/// An accent action row ("Get the phone app ↗", "Sign in to Kore's tailnet ↗").
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
    let name: String
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
        .accessibilityLabel(Text("More for \(name)"))
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
                .accessibilityLabel(Text("\(left / 60) min \(left % 60) s left"))
                .storyID(StoryID.Net.countdown)
        }
    }
}

/// Where the Devices popup hangs (storylines).
@MainActor
package enum DevicesPopupPlace {
    /// Storylines: the popup shows in `window`, hanging under that window's icon (below it, one of
    /// its edges lined up with the icon's).
    package static func showsUnderIcon(in window: NSWindow) -> Bool {
        guard NetPopupHost.shared.isShowing("devices"), NetPopupHost.shared.window === window, let popup = NetPopupHost.shared.frame,
              let icon = NetAnchors.icon(in: window), let content = window.contentView
        else { return false }
        let under = content.convert(icon.bounds, from: icon)
        let lined = abs(popup.minX - under.minX) < 1 || abs(popup.maxX - under.maxX) < 1
        let below = content.isFlipped ? popup.minY >= under.maxY : popup.maxY <= under.minY
        return lined && below
    }
}

extension View {
    /// An inline text action's hit area: the line's height, with nothing drawn bigger.
    func netHit() -> some View { frame(minHeight: Size.Net.line).contentShape(Rectangle()) }
}
