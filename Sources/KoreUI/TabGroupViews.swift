import AppKit
import SwiftUI

/// A tab group's chip before its tabs: its name in its colour on a wash of it, or a dot for an
/// unnamed one. A click folds the group to the chip (its count, and a point while a chat in it
/// works or waits) or opens it; a right-click opens its popup; a drag moves the whole group.
struct GroupChip: View {
    let group: TabGroup
    let members: [ChatTab]
    let width: CGFloat
    /// An open group's chip while the tabs show letters: the dot alone.
    let dotOnly: Bool
    let height: CGFloat
    let fold: () -> Void
    let edit: () -> Void
    @StateObject private var hovered = Local(false)

    private var line: String {
        let name = group.name.isEmpty ? "Group" : group.name
        return "\(name) · \(members.count) \(members.count == 1 ? "tab" : "tabs")"
    }

    var body: some View {
        let color = Theme.TabGroups.color(group.color)
        Button(action: fold) {
            HStack(spacing: Space.sm) {
                if dotOnly || group.name.isEmpty {
                    Circle().fill(color).frame(width: Size.TabGroup.dot, height: Size.TabGroup.dot)
                } else {
                    Text(group.name)
                        .font(Chrome.label.weight(.semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if group.folded, !dotOnly {
                    Text(String(members.count))
                        .font(Chrome.labelDigits.weight(.medium))
                        .foregroundStyle(Theme.TabGroups.count(group.color))
                        .lineLimit(1)
                    FoldedPoint(members: members, group: group.id)
                }
            }
            .padding(.horizontal, dotOnly || (group.name.isEmpty && !group.folded) ? 0 : Size.TabGroup.chipPadding)
            .frame(width: width, height: Size.TabGroup.chipHeight)
            .background(Theme.TabGroups.wash(group.color, hovered: hovered.value), in: RoundedRectangle(cornerRadius: Radius.chip))
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(line)
        .accessibilityLabel(Text(line))
        .koreSecondaryClick("tab-group", perform: edit)
        .storyID(StoryID.TabGroups.chip(group.id))
    }
}

/// A folded group's one cue: a point while a chat in it works, in sand while one waits for an
/// answer. Only a folded chip watches its chats.
private struct FoldedPoint: View {
    let members: [ChatTab]
    let group: UUID

    var body: some View {
        let chats = members.compactMap { $0.agent == nil ? $0.chat : nil }
        let waiting = chats.contains { BoardTileState.of($0, unseen: false) == .waiting }
        let working = chats.contains { TabWork.running($0) }
        Circle()
            .fill(waiting ? Theme.TabGroups.waiting : Theme.TabGroups.working)
            .frame(width: waiting || working ? Size.TabGroup.point : 0, height: Size.TabGroup.point)
            .opacity(waiting || working ? 1 : 0)
            .storyMark(StoryID.TabGroups.chip(group).part(waiting ? .lit : working ? .working : .done))
    }
}

/// The line of each open group's colour under its tabs, drawn as one shape per group.
struct GroupLines: View {
    struct Line: Identifiable, Equatable {
        let id: UUID
        let color: TabGroupColor
        let from: CGFloat
        let to: CGFloat
    }

    let lines: [Line]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(lines) { line in
                Capsule()
                    .fill(Theme.TabGroups.line(line.color))
                    .frame(width: max(0, line.to - line.from), height: Size.TabGroup.line)
                    .offset(x: line.from)
                    .storyMark(StoryID.TabGroups.line(line.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

/// A group's popup, under its chip: the name, the colours, then New tab in group, Ungroup and
/// Close group. Changes apply as they're made; Return, Esc or a click elsewhere closes it.
/// Closing a group with a chat working asks once, here.
struct TabGroupPopup: View {
    let workspace: Workspace
    let edit: TabGroupEdit
    /// The chip: a click on it isn't outside (its own click folds the group).
    let anchor: () -> CGRect
    let close: () -> Void
    @StateObject private var name = Local("")
    @StateObject private var asking = Local(false)
    @FocusState private var naming: Bool
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    var body: some View {
        let group = workspace.tabGroups.group(edit.id)
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("", text: $name.value, prompt: Text("Name this group").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Chrome.body)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Space.md)
                .frame(height: Size.TabGroup.field)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(naming ? Theme.accentLine : Theme.border, lineWidth: Stroke.hairline)
                }
                .focused($naming)
                .onSubmit(close)
                .onExitCommand(perform: close)
                .onChange(of: name.value) { _, value in workspace.rename(group: edit.id, to: value) }
                .storyID(StoryID.TabGroups.name)
            HStack(spacing: Space.sm) {
                ForEach(TabGroupColor.allCases, id: \.self) { color in
                    GroupSwatch(color: color, picked: group?.color == color) { workspace.recolor(group: edit.id, color) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
            if asking.value {
                confirm
            } else {
                VStack(spacing: 0) {
                    GroupPopupRow(title: "New tab in group", story: StoryID.TabGroups.newTab) {
                        close()
                        workspace.newTab(in: edit.id)
                    }
                    GroupPopupRow(title: "Ungroup", story: StoryID.TabGroups.ungroup) {
                        close()
                        workspace.ungroup(edit.id)
                    }
                    GroupPopupRow(title: "Close group", detail: tabsWord, danger: true, story: StoryID.TabGroups.close) { closeGroup() }
                }
            }
        }
        .padding(Space.lg)
        .frame(width: Size.TabGroup.popupWidth)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { window.value = $0 })
        .storyID(StoryID.TabGroups.popup)
        .onAppear {
            name.value = group?.name ?? ""
            if edit.naming { naming = true }
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    private var tabsWord: String {
        let n = workspace.members(of: edit.id).count
        return "\(n) \(n == 1 ? "tab" : "tabs")"
    }

    private var confirm: some View {
        let busy = workspace.busyCount(in: edit.id)
        return VStack(alignment: .leading, spacing: Space.md) {
            Text("\(busy) \(busy == 1 ? "chat is" : "chats are") working. Closing stops \(busy == 1 ? "it" : "them").")
                .font(Chrome.label)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.md) {
                Spacer(minLength: 0)
                Button("Cancel") { asking.value = false }.smallButton()
                Button("Stop and close") { finishClose() }
                    .smallButton(danger: true)
                    .storyID(StoryID.TabGroups.stopAndClose)
            }
        }
    }

    private func closeGroup() {
        if workspace.busyCount(in: edit.id) > 0 {
            asking.value = true
        } else {
            finishClose()
        }
    }

    private func finishClose() {
        let id = edit.id
        close()
        workspace.closeGroup(id)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            // Esc with the name field not taking keys (it closes the popup itself when it is).
            if event.keyCode == 53, !naming {
                close()
                return nil
            }
            return event
        }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point), !anchor().contains(point) { close() }
        return event
    }
}

/// One of the group's colours: a dot, ringed when it's the group's.
private struct GroupSwatch: View {
    let color: TabGroupColor
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(Theme.TabGroups.color(color))
                .frame(width: Size.TabGroup.swatch, height: Size.TabGroup.swatch)
                .padding(Size.TabGroup.swatchRing)
                .overlay {
                    if picked { Circle().strokeBorder(Theme.TabGroups.color(color), lineWidth: Stroke.emphasis) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .storyID(StoryID.TabGroups.swatch(color.rawValue))
    }
}

/// A row of the group's popup, filled under the pointer.
private struct GroupPopupRow: View {
    let title: String
    var detail: String? = nil
    var danger = false
    let story: StoryID
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Text(title).font(Chrome.body).foregroundStyle(danger ? Theme.danger : Theme.text)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(Chrome.label).foregroundStyle(Theme.tertiary) }
            }
            .padding(.horizontal, Space.md)
            .frame(height: Size.Picker.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(hovered.value)
        .onHover { hovered.value = $0 }
        .storyID(story)
    }
}
