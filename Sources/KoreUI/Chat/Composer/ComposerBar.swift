import SwiftUI

/// The row under the text field: + · / · context wheel · model … mode · send. In a narrow tile
/// it steps down (effort, then labels, then the model pill go) instead of clipping.
struct ComposerBar: View {
    let chat: Chat
    let attach: () -> Void
    let slash: () -> Void
    /// The / key's frame (global): a press there leaves the / menu to it.
    var slashFrame: (CGRect) -> Void = { _ in }
    @StateObject private var plusHovered = Local(false)
    @StateObject private var slashHovered = Local(false)

    var body: some View {
        HStack(spacing: Space.xxl) {
            // Each key takes clicks over a whole icon-button square, not just its inked pixels;
            // the pair takes the same room as before, so nothing in the row moves.
            HStack(spacing: 0) {
                Button(action: attach) {
                    Image(systemName: "plus")
                        .font(Glyph.attach)
                        .foregroundStyle(plusHovered.value ? Theme.text : Theme.secondary)
                        .hitBox()
                }
                .buttonStyle(.plain)
                .onHover { plusHovered.value = $0 }
                .help("Attach")
                .accessibilityLabel(Text("Attach files"))
                .storyID(StoryID.Composer.attach)

                Button(action: slash) {
                    let color = slashHovered.value ? Theme.text : Theme.secondary
                    SlashMark()
                        .stroke(color, style: StrokeStyle(lineWidth: Size.slashLine, lineCap: .round))
                        .frame(width: Size.slashGlyph, height: Size.slashGlyph)
                        .overlay(RoundedRectangle(cornerRadius: Radius.glyph).stroke(color, lineWidth: Size.slashStroke))
                        .hitBox()
                }
                .buttonStyle(.plain)
                .onHover { slashHovered.value = $0 }
                .help("Slash commands")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slashFrame($0) }
                .storyID(StoryID.Composer.slash)
            }
            .padding(.horizontal, -Space.sm)

            // The slot is kept once there's a session, so the bar doesn't shift when usage arrives.
            if chat.status.sessionId != nil {
                ContextWheel(chat: chat)
                    .storyID(StoryID.Composer.context)
                    .padding(.horizontal, -Space.sm)
            }

            ViewThatFits(in: .horizontal) {
                controls(.full)
                controls(.noEffort)
                controls(.iconsOnly)
                controls(.minimal)
            }

            sendButton
        }
        .padding(Inset.composerBar)
    }

    private enum Density { case full, noEffort, iconsOnly, minimal }

    private func controls(_ density: Density) -> some View {
        HStack(spacing: Space.xxl) {
            if !chat.controls.models.isEmpty && density != .minimal {
                // Pressed by a storyline, the menu's opening as far as the other popups go: the
                // system menu's own tracking would hold the storyline.
                ModelMenu(chat: chat, showEffort: density == .full)
                    .storyID(StoryID.Composer.model, press: { chat.closePopups(keeping: .menu) })
            }
            Spacer(minLength: 0)
            if let plan = chat.provider.planToggle, chat.controls.planMode {
                PlanChip(mode: plan) { chat.setPlanMode(false) }
            }
            ModeMenu(chat: chat, showLabel: density == .full || density == .noEffort)
                .storyID(StoryID.Composer.mode, press: { chat.closePopups(keeping: .menu) })
        }
    }

    private var sendButton: some View {
        Button {
            chat.status.isRunning ? chat.stop() : chat.send()
        } label: {
            Image(systemName: chat.status.isRunning ? "stop.fill" : "arrow.up")
                .font(Glyph.send)
                .foregroundStyle(Theme.background)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(Theme.text, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(!chat.status.isRunning && !chat.canSend)
        .opacity(!chat.status.isRunning && !chat.canSend ? 0.3 : 1)
        .help(chat.status.isRunning ? "Stop (Esc)" : "")
        .accessibilityLabel(Text(chat.status.isRunning ? "Stop" : "Send"))
        // One button: Stop while a turn runs, else Send.
        .storyID(chat.status.isRunning ? StoryID.Composer.stop : StoryID.Composer.send)
    }
}

/// Model and effort, from the CLI's own list.
struct ModelMenu: View {
    let chat: Chat
    var showEffort = true

    var body: some View {
        Menu {
            Section("Model") {
                ForEach(chat.controls.models) { option in
                    Button {
                        chat.setModel(option)
                    } label: {
                        if option.id == chat.controls.modelId {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            }
            if let efforts = chat.controls.currentModel?.efforts, !efforts.isEmpty {
                Section("Effort") {
                    ForEach(efforts, id: \.self) { level in
                        Button {
                            chat.setEffort(level)
                        } label: {
                            if level == chat.controls.effort {
                                Label(Self.effortName(level), systemImage: "checkmark")
                            } else {
                                Text(Self.effortName(level))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Space.sm) {
                Text(chat.controls.modelLabel)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if showEffort, let effort = chat.controls.effortLabel {
                    Text(effort)
                        .font(TextStyle.label)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.xs)
            .background(Theme.surfaceHover, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // The pill says it, unless a narrow bar has hidden the effort.
        .help(showEffort ? "" : chat.controls.effortLabel.map { "\(chat.controls.modelLabel) · \($0)" } ?? "")
    }

    static func effortName(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
    }
}

/// The provider's modes (icon + label), as in its VS Code extension.
struct ModeMenu: View {
    let chat: Chat
    var showLabel = true
    /// The agent's change, fading out of the pill's fill.
    @StateObject private var flash = Local(0.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            ForEach(chat.controls.availableModes) { mode in
                toggle(mode, isOn: chat.controls.mode == mode.id) { chat.setMode(mode.id) }
            }
            if let plan = chat.provider.planToggle {
                Divider()
                toggle(plan, isOn: chat.controls.planMode) { chat.setPlanMode(!chat.controls.planMode) }
            }
        } label: {
            // A plan toggle shows as its own chip, so the menu keeps the permissions mode.
            let mode = chat.provider.planToggle != nil ? chat.controls.permissionsMode : chat.controls.activeMode
            HStack(spacing: Space.xs) {
                ModeIcon(mode: mode)
                if showLabel {
                    Text(mode.label).font(mode.tint == nil ? TextStyle.label : TextStyle.labelMedium).lineLimit(1)
                }
            }
            .foregroundStyle(mode.tint ?? Theme.secondary)
            .background(Theme.modeFlash(mode.rung).opacity(flash.value), in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(chat.controls.changedBy.map { "Changed by \($0)" } ?? "Mode (⇧Tab)")
        // Only the agent's own change flashes, not a switch to a chat that had one.
        .onChange(of: AgentChange(chat: chat.id, seq: chat.controls.agentChangeSeq)) { old, new in
            guard !reduceMotion, old.chat == new.chat else { return }
            flash.value = 1
            // From the next pass, so the fade starts from the full flash.
            DispatchQueue.main.async { withAnimation(Motion.modeFlash) { flash.value = 0 } }
        }
    }

    private struct AgentChange: Equatable {
        let chat: UUID
        let seq: Int
    }

    private func toggle(_ mode: ModeOption, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Label {
                Text(mode.label)
            } icon: {
                Image(nsImage: ModeIcons.image(mode.icon))
            }
        }
    }
}

/// The "/" key's stroke, drawn rather than set in type so it sits in the middle of its box.
private struct SlashMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.27))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.73))
        }
    }
}

extension View {
    /// A glyph key's click area: the icon-button square around it.
    fileprivate func hitBox() -> some View {
        frame(width: Size.iconButton, height: Size.iconButton).contentShape(Rectangle())
    }
}
