import AppKit
import KoreCore
import SwiftUI
import SwiftTerm

/// The explorer is outside this column and therefore keeps its entire height.
struct TerminalWorkspace: View {
    let workspace: Workspace

    var body: some View {
        let panel = workspace.terminals
        GeometryReader { geometry in
            let height = Layout.Terminal.fitting(panel.height, available: geometry.size.height - Layout.Explorer.sashHit, maximized: panel.maximized)
            VStack(spacing: 0) {
                WorkspaceView(workspace: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panel.isOpen {
                    TerminalSash(panel: panel, available: geometry.size.height - Layout.Explorer.sashHit)
                    TerminalPanelView(panel: panel)
                        .frame(height: height)
                }
            }
        }
        .environment(\.terminalPanel, panel)
        .background(WindowReader { window in
            panel.windowVisible = window?.occlusionState.contains(.visible) ?? false
        })
        .onChange(of: panel.isOpen) { _, open in
            if open { panel.windowVisible = workspace.window?.occlusionState.contains(.visible) ?? false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === workspace.window else { return }
            panel.windowVisible = window.occlusionState.contains(.visible)
        }
    }
}

private struct TerminalPanelView: View {
    let panel: TerminalPanel

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if let active = panel.active {
                    VStack(alignment: .leading, spacing: 0) {
                        TerminalHost(entry: active, panel: panel)
                            .storyMark(StoryID.Terminal.output)
                        if let failure = active.shell?.failure {
                            Text(failure).font(Chrome.label).foregroundStyle(Theme.warning).padding(Space.sm)
                        } else if let failure = active.command?.failure {
                            Text(failure).font(Chrome.label).foregroundStyle(Theme.warning).padding(Space.sm)
                        } else if !active.outputAvailable {
                            Text("Output is no longer available").font(Chrome.label).foregroundStyle(Theme.secondary).padding(Space.sm)
                        } else if active.truncated {
                            Text("Showing the latest output").font(Chrome.label).foregroundStyle(Theme.tertiary).padding(Space.xs)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The native view sits inside the inset, so its columns fit the inset width.
                    .padding(.horizontal, Layout.Terminal.side)
                    .padding(.top, Layout.Terminal.top)
                    .padding(.bottom, Space.xs)
                    .task(id: "\(active.id)-\(active.command?.isLive ?? false)-\(panel.windowVisible)") {
                        guard active.shell == nil, panel.windowVisible else { return }
                        repeat {
                            await active.refreshOutput()
                            guard !Task.isCancelled, active.command?.isLive == true else { return }
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        } while !Task.isCancelled
                    }
                }
                if panel.entries.count > 1 {
                    Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
                    ScrollView {
                        VStack(spacing: Space.xxs) {
                            ForEach(panel.entries) { entry in TerminalListRow(entry: entry, panel: panel) }
                        }
                        .padding(Space.xs)
                    }
                    .frame(width: Layout.Terminal.listWidth)
                }
            }
        }
        .background(Theme.background)
        .storyMark(StoryID.Terminal.panel)
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text("Terminal").font(Chrome.label).foregroundStyle(Theme.secondary)
            if let active = panel.active {
                if panel.renaming == active.id {
                    TerminalNameField(panel: panel, entryID: active.id).id(active.id).frame(maxWidth: Layout.Terminal.listWidth * 2)
                } else {
                    Text(active.title).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                        .storyID(StoryID.Terminal.title)
                        .help(active.title)
                        .koreContextMenu("terminal") { terminalOptions(active, panel: panel) }
                    IconButton(symbol: "pencil", help: "Rename terminal") { panel.startRename(active) }
                        .storyID(StoryID.Terminal.rename)
                }
                if active.shell == nil {
                    if active.command?.isLive == true { BlinkingDot() }
                    Text(active.command?.isLive == true ? "Read only · running" : "Read only · ended")
                        .font(Chrome.label).foregroundStyle(Theme.tertiary).lineLimit(1)
                    if let command = active.command, command.canStop, let chat = active.chat {
                        Button(command.stopping ? "Stopping…" : "Stop") { chat.stopCommand(command.id) }
                            .smallButton().disabled(command.stopping)
                            .storyID(StoryID.Terminal.stop)
                    }
                } else if active.shell?.ended == true {
                    Text("Exited").font(Chrome.label).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let active = panel.active {
                IconButton(symbol: "trash", help: active.shell == nil ? "Close output" : "Close terminal") { panel.requestClose(active) }
                    .storyID(StoryID.Terminal.close)
            }
            IconButton(symbol: "plus", help: "New terminal (⌃⇧`)") { panel.newShell() }
                .storyID(StoryID.Terminal.newShell)
            IconButton(symbol: panel.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: panel.maximized ? "Restore terminal size" : "Maximize terminal") { panel.maximized.toggle() }
                .storyID(StoryID.Terminal.maximize)
            IconButton(symbol: "chevron.down", help: "Hide terminal (⌃`)") { panel.hide() }
                .storyID(StoryID.Terminal.hide)
        }
        .padding(.horizontal, Space.md)
        .frame(height: Layout.Terminal.header)
    }
}

private struct TerminalListRow: View {
    let entry: TerminalEntry
    let panel: TerminalPanel
    @StateObject private var hovered = Local(false)

    var body: some View {
        HStack(spacing: Space.xs) {
            Button { panel.select(entry) } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: entry.shell == nil ? "doc.text" : "terminal").font(Chrome.label)
                    Text(entry.title).font(Chrome.label).lineLimit(1).truncationMode(.middle)
                    // The header says it for the shown one; a row says it for the rest.
                    if let command = entry.command, command.isLive {
                        BlinkingDot().storyMark(StoryID.Terminal.running(command.id))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(panel.selected == entry.id ? Theme.text : Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: Size.hitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .storyID(StoryID.Terminal.entry(entry.id))
            IconButton(symbol: "xmark", help: entry.shell == nil ? "Close output" : "Close terminal") { panel.requestClose(entry) }
                .opacity(hovered.value || panel.selected == entry.id ? 1 : 0)
                .storyID(StoryID.Terminal.entry(entry.id).part(.close), press: { panel.requestClose(entry) })
        }
        .padding(.leading, Space.sm)
        .background(panel.selected == entry.id ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .onHover { hovered.value = $0 }
        .help(entry.title)
        .koreContextMenu("terminal") { terminalOptions(entry, panel: panel) }
        .accessibilityAction(named: "Rename") { panel.startRename(entry) }
    }
}

@MainActor private func terminalOptions(_ entry: TerminalEntry, panel: TerminalPanel) -> [OptionItem] {
    var items = [OptionItem("Rename…") { panel.startRename(entry) }]
    if entry.customTitle != nil { items.append(OptionItem("Use Default Name") { entry.rename("") }) }
    return items
}

private struct TerminalNameField: View {
    @Bindable var panel: TerminalPanel
    let entryID: UUID
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Terminal name", text: $panel.nameDraft)
            .fieldWell(focused: focused)
            .focused($focused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, now in if !now { finish(commit: true, restoreFocus: false) } }
            .onAppear { focused = true }
            .storyID(StoryID.Terminal.nameField)
    }

    private func finish(commit: Bool, restoreFocus: Bool = true) {
        guard panel.renaming == entryID else { return }
        panel.finishRename(commit: commit, restoreFocus: restoreFocus)
    }
}

private struct TerminalSash: View {
    let panel: TerminalPanel
    let available: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var start = Held<CGFloat?>(nil)

    var body: some View {
        Color.clear
            .frame(height: Layout.Explorer.sashHit)
            .overlay { Rectangle().fill(hovered.value ? Theme.accentLine : Theme.border).frame(height: Stroke.hairline) }
            .contentShape(Rectangle())
            .allowsWindowActivationEvents(true)
            .onHover { inside in
                hovered.value = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let base = start.value ?? Layout.Terminal.fitting(panel.height, available: available, maximized: panel.maximized)
                    start.value = base
                    panel.maximized = false
                    panel.height = Layout.Terminal.fitting(base - drag.translation.height, available: available, maximized: false)
                }
                .onEnded { _ in
                    start.value = nil
                    UILog.event("terminal-resize", ["height": "\(Int(panel.height))"])
                })
            .onTapGesture(count: 2) { panel.height = Layout.Terminal.height; panel.maximized = false }
            .zIndex(2)
            .storyMark(StoryID.Terminal.sash)
            .onDisappear { if hovered.value { NSCursor.pop() } }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let entry: TerminalEntry
    let panel: TerminalPanel

    func makeNSView(context: Context) -> Container { Container() }
    func updateNSView(_ host: Container, context: Context) {
        let serial = panel.focusSerial
        host.install(entry, focus: serial, allowsFocus: panel.renaming == nil) { panel.appliedFocus(serial) }
    }

    final class Container: NSView {
        private var entry: TerminalEntry?
        private var focus = -1
        private var needsFocus = false
        private var allowsFocus = true
        private var applied: (() -> Void)?
        override var isFlipped: Bool { true }

        func install(_ entry: TerminalEntry, focus: Int, allowsFocus: Bool, applied: @escaping () -> Void) {
            self.applied = applied
            self.allowsFocus = allowsFocus
            if self.entry !== entry {
                subviews.forEach { $0.removeFromSuperview() }
                self.entry = entry
                entry.view.removeFromSuperview()
                addSubview(entry.view)
                entry.view.autoresizingMask = [.width, .height]
                entry.view.frame = bounds
            }
            if self.focus != focus { needsFocus = true; self.focus = focus }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let entry, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            entry.view.frame = bounds
            entry.shell?.start()
            if needsFocus {
                needsFocus = false
                let serial = focus
                afterThisFrame { [weak self] in
                    guard let self, self.allowsFocus, self.focus == serial, self.entry === entry, let window = self.window else { return }
                    window.makeFirstResponder(entry.view)
                    self.applied?()
                }
            }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    }
}

/// Window-scoped shortcuts work even with a native terminal as first responder, and never
/// act on another window's panel. The Terminal menu exposes the same actions.
struct TerminalKeys: ViewModifier {
    let workspace: Workspace
    @StateObject private var monitor = Held<Any?>(nil)

    func body(content: Content) -> some View {
        content.onAppear {
            guard monitor.value == nil else { return }
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard event.window === workspace.window,
                      event.charactersIgnoringModifiers == "`" || event.charactersIgnoringModifiers == "~",
                      flags == .control || flags == [.control, .shift] else { return event }
                guard !event.isARepeat else { return nil }
                if flags.contains(.shift) { workspace.terminals.newShell() } else { workspace.terminals.toggle() }
                return nil
            }
        }
        .onDisappear {
            if let monitor = monitor.value { NSEvent.removeMonitor(monitor) }
            monitor.value = nil
        }
    }
}
