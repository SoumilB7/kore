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
                .onHover { hovering in
                    plusHovered.value = hovering
                    // Resting on +: the picker connects now, so the click opens it at once.
                    guard hovering else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [plusHovered] in
                        MainActor.assumeIsolated { if plusHovered.value { AttachPanel.warm() } }
                    }
                }
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

            // The ring keeps its own gap, so with none Send sits where it always has.
            HStack(spacing: 0) {
                ResetSendButton(chat: chat)
                sendButton
            }
        }
        .padding(Inset.composerBar)
    }

    private enum Density { case full, noEffort, iconsOnly, minimal }

    private func controls(_ density: Density) -> some View {
        HStack(spacing: Space.xxl) {
            if !chat.controls.models.isEmpty && density != .minimal {
                ModelMenu(chat: chat, showEffort: density == .full)
                    .storyID(StoryID.Composer.model, press: { chat.togglePicker(.model) })
            }
            Spacer(minLength: 0)
            if let plan = chat.provider.planToggle, chat.controls.planMode {
                PlanChip(mode: plan) { chat.setPlanMode(false) }
            }
            ModeMenu(chat: chat, showLabel: density == .full || density == .noEffort)
                .storyID(StoryID.Composer.mode, press: { chat.togglePicker(.mode) })
        }
    }

    private var sendButton: some View {
        // Stop while a turn runs or the chat compacts. The press does what it showed: a Stop
        // that lands just after the work ended does nothing, never a send.
        let stops = chat.isBusy
        let off = !stops && !chat.canSend
        return Button {
            stops ? chat.stop() : chat.send()
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(Glyph.send)
                .foregroundStyle(off ? Theme.sendOffGlyph : Theme.background)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(off ? Theme.sendOff : Theme.text, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .disabled(off)
        .help(stops ? "Stop (Esc)" : "Send (↩)")
        .accessibilityLabel(Text(stops ? "Stop" : "Send"))
        // One button: Stop while a turn runs or a compaction does, else Send.
        .storyID(stops ? StoryID.Composer.stop : StoryID.Composer.send)
    }
}

/// The model and effort pill: opens the model picker over the composer, from the CLI's own list.
struct ModelMenu: View {
    let chat: Chat
    var showEffort = true

    var body: some View {
        let open = chat.picker.open == .model
        Button {
            chat.togglePicker(.model)
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
            .background(open ? Theme.surfaceRaised : Theme.surfaceHover, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chat.picker.chips[.model] = $0 }
        // The pill says it, unless a narrow bar has hidden the effort.
        .help(showEffort ? "" : chat.controls.effortLabel.map { "\(chat.controls.modelLabel) · \($0)" } ?? "")
    }
}

/// The provider's mode (icon + label), as in its VS Code extension: opens the mode picker.
struct ModeMenu: View {
    let chat: Chat
    var showLabel = true
    /// The agent's change, fading out of the pill's fill.
    @StateObject private var flash = Local(0.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A plan toggle shows as its own chip, so the pill keeps the permissions mode.
        let mode = chat.provider.planToggle != nil ? chat.controls.permissionsMode : chat.controls.activeMode
        let open = chat.picker.open == .mode
        Button {
            chat.togglePicker(.mode)
        } label: {
            // The icon's box is padded past its ink, so the line takes the label's height (a hidden
            // one when icons only): the capsule is as tall as the model pill's.
            ZStack {
                Text(verbatim: " ").font(TextStyle.labelMedium).hidden()
                HStack(spacing: Space.xs) {
                    ModeIcon(mode: mode).frame(height: 0) // lint:allow takes no height, drawn over it
                    if showLabel {
                        Text(mode.label).font(mode.tint == nil ? TextStyle.label : TextStyle.labelMedium).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(mode.tint ?? (open ? Theme.text : Theme.secondary))
            // The model pill's capsule, so the row's two pickers match at rest.
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.xs)
            .background {
                ZStack {
                    Capsule().fill(open ? Theme.surfaceRaised : Theme.surfaceHover)
                    Capsule().fill(Theme.modeFlash(mode.rung).opacity(flash.value))
                }
            }
            .padding(.horizontal, -Space.xs)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chat.picker.chips[.mode] = $0 }
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
}

/// The "/" key's stroke, drawn rather than set in type so it sits in the middle of its box.
struct SlashMark: Shape {
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
