import KoreCore
import SwiftUI

/// ">_ 2" after an agent's meter (the root's included): its live commands, running or armed.
/// Nothing at 0.
struct CommandCue: View {
    let count: Int
    var dot = true

    var body: some View {
        if count > 0 {
            HStack(spacing: Space.xxs) {
                if dot { Text("·").foregroundStyle(Theme.secondary).padding(.horizontal, Space.xs) }
                Text(">_").font(Glyph.commandCue).foregroundStyle(Theme.accent)
                Text("\(count)").font(TextStyle.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            .fixedSize()
            .help(count == 1 ? "1 in background" : "\(count) in background")
            .accessibilityLabel(Text(count == 1 ? "1 command in background" : "\(count) commands in background"))
        }
    }
}

/// "BACKGROUND" in a pane, above the agent's prompt: the live commands first, newest start
/// first, each with its age and its actions; then the finished ones, most recently ended first,
/// one muted line each. More than 50 finished show their newest 20, then "Show N more". A row
/// opens in place on its click. Present only while the owner has any.
struct CommandsSection: View {
    let chat: Chat
    let rows: (live: [ActiveCommand], finished: [ActiveCommand])
    /// Each row says which agent it came from (the Still running pane), and selects it.
    var showsOwner = false

    private var map: AgentMapState { chat.agentMap }
    static let manyFinished = 50
    static let firstFinished = 20

    var body: some View {
        if !rows.live.isEmpty || !rows.finished.isEmpty {
            let stoppable = rows.live.filter(\.canStop)
            let finished =
                rows.finished.count > Self.manyFinished && !map.allFinished ? Array(rows.finished.prefix(Self.firstFinished)) : rows.finished
            VStack(alignment: .leading, spacing: 0) {
                header(stoppable)
                ForEach(rows.live) { row($0) }
                ForEach(finished) { row($0) }
                if finished.count < rows.finished.count {
                    TextButton("Show \(rows.finished.count - finished.count) more", font: TextStyle.label) { map.allFinished = true }
                        .padding(.vertical, Space.sm)
                        .storyID(StoryID.AgentMap.moreCommands, press: { map.allFinished = true })
                }
            }
            .frame(maxWidth: Layout.Commands.width, alignment: .leading)
            .padding(.bottom, Space.xl)
            .onAppear { chat.watchCommands(true) }
            .onDisappear { chat.watchCommands(false) }
        }
    }

    /// The eyebrow, and Stop all at its right for two or more that can stop.
    private func header(_ stoppable: [ActiveCommand]) -> some View {
        let id = StoryID.AgentMap.stopAll
        return HStack(spacing: Space.md) {
            Text("BACKGROUND").font(TextStyle.eyebrow).foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
            if stoppable.count >= 2 {
                if map.askingStop == AgentMapState.stopAll {
                    Text("Stop all \(stoppable.count)?").font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
                    Button("Yes, stop all") {
                        map.askingStop = nil
                        for command in stoppable { chat.stopCommand(command.id) }
                    }
                    .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                    .storyID(id.part(.allow))
                    Button("No, go back") { map.askingStop = nil }
                        .buttonStyle(SubtleButtonStyle(small: true))
                        .storyID(id.part(.cancel))
                } else {
                    TextButton("Stop all", font: TextStyle.label, color: Theme.secondary) { map.askingStop = AgentMapState.stopAll }
                        .storyID(id, press: { map.askingStop = AgentMapState.stopAll })
                }
            }
        }
        .frame(height: Size.smallButton + Space.xs)
        .padding(.bottom, Space.xs)
    }

    private func row(_ command: ActiveCommand) -> some View {
        CommandRow(
            chat: chat, command: command, open: map.openCommand == command.id,
            // A confirm whose command ended meanwhile goes away.
            asking: map.askingStop == command.id && command.canStop,
            owner: showsOwner ? command.owner.sub.flatMap { chat.transcript.agent($0) } : nil)
    }
}

/// One command: a point (live), its title, its age or how it ended, and its actions; opened, its
/// command, kind, folder and start, and the end of its output, read while open.
private struct CommandRow: View {
    let chat: Chat
    let command: ActiveCommand
    let open: Bool
    let asking: Bool
    let owner: TranscriptStore.AgentInfo?
    @StateObject private var hovered = Local(false)

    private var map: AgentMapState { chat.agentMap }
    private var id: StoryID { StoryID.AgentMap.command(command.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.lg) {
                point.frame(width: Space.xxl)
                title.frame(maxWidth: .infinity, alignment: .leading)
                CommandTime(command: command)
                actions
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: (command.isLive ? Layout.Commands.liveRow : Layout.Commands.finishedRow) * Zoom.shared.scale)
            .hoverFill(open || hovered.value, open ? Theme.surfaceHover : Theme.toolHover, radius: Radius.control)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovered.value = $0 }
            .padding(.horizontal, -Space.md)
            .storyID(id, press: toggle)
            if let failure = command.failure {
                Text(failure).font(TextStyle.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                    .padding(.leading, Space.xxl + Space.lg).padding(.bottom, Space.xs)
            }
            if open { CommandDetail(chat: chat, command: command).padding(.vertical, Space.xxs) }
        }
    }

    private func toggle() {
        map.openCommand = open ? nil : command.id
    }

    @ViewBuilder private var point: some View {
        if command.isLive {
            Circle().fill(Theme.accent).frame(width: Size.commandPoint, height: Size.commandPoint)
                .background(Circle().fill(Theme.accent.opacity(0.15)).frame(width: Size.commandPoint + 6, height: Size.commandPoint + 6))
        } else if case .failed = command.state {
            Circle().fill(Theme.danger).frame(width: Size.commandPoint - 1, height: Size.commandPoint - 1)
        }
    }

    private var title: some View {
        // Codex has no description: its command, in mono.
        let mono = command.title == command.command && command.kind != .scheduled
        return HStack(spacing: Space.sm) {
            Text(command.title)
                .font(mono ? TextStyle.code : (command.isLive ? TextStyle.body : TextStyle.label))
                .foregroundStyle(command.isLive ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let owner {
                Button {
                    map.select(owner.id)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text("· from").foregroundStyle(Theme.secondary)
                        AgentAvatar(index: owner.index, name: owner.name, status: owner.status, background: owner.background, place: .crumb)
                        Text(owner.name).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .font(TextStyle.caption)
                }
                .buttonStyle(.plain)
                .help("Select \(owner.name)")
            }
        }
        .help(command.command ?? command.title)
    }

    @ViewBuilder private var actions: some View {
        if command.isLive && command.kind != .scheduled {
            HStack(spacing: Space.sm) {
                if asking {
                    Text("Stop this?").font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                    Button("Yes, stop") {
                        map.askingStop = nil
                        chat.stopCommand(command.id)
                    }
                    .buttonStyle(SubtleButtonStyle(prominent: true, small: true))
                    .storyID(id.part(.allow))
                    Button("No, go back") { map.askingStop = nil }
                        .buttonStyle(SubtleButtonStyle(small: true))
                        .storyID(id.part(.cancel))
                } else if command.stopping {
                    Text("Stopping…").font(TextStyle.label).foregroundStyle(Theme.tertiary).fixedSize()
                } else {
                    if command.canBackground {
                        Button("Run in background") { chat.runInBackground(command.id) }
                            .buttonStyle(QuietSmallButtonStyle())
                            .storyID(id.part(.background))
                    }
                    Button("Stop") { map.askingStop = command.id }
                        .buttonStyle(SubtleButtonStyle(small: true))
                        .storyID(id.part(.stop))
                }
            }
            .fixedSize()
        }
    }
}

/// Live: its age, two units ("29h 39m"), ticking; a job, when it fires. Finished: a word only if
/// it didn't simply succeed ("exit 1" in red, "stopped", "ended"…), and how long it ran.
private struct CommandTime: View {
    let command: ActiveCommand

    var body: some View {
        Group {
            if command.kind == .scheduled {
                Text(CommandText.schedule(command)).foregroundStyle(command.isLive ? Theme.secondary : Theme.tertiary)
            } else if command.isLive, let start = command.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(CommandText.age(context.date.timeIntervalSince(start))).foregroundStyle(Theme.secondary)
                }
            } else {
                finished
            }
        }
        .font(TextStyle.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private var finished: Text {
        let duration = command.duration.map(CommandText.age)
        let word = CommandText.word(command.state)
        guard let word else { return Text(duration ?? "").foregroundColor(Theme.tertiary) }
        let said = Text(word).foregroundColor(command.state.isFailure ? Theme.danger : Theme.tertiary)
        return duration.map { said + Text(" · \($0)").foregroundColor(Theme.tertiary) } ?? said
    }
}

/// An opened row: the command in a well, what it is, where and since when, and the end of its
/// output, read every second while it's open and runs (once when it has ended).
private struct CommandDetail: View {
    let chat: Chat
    let command: ActiveCommand
    @StateObject private var tail = Local<OutputTail?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(command.command ?? command.title)
                .font(TextStyle.code)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CommandText.facts(command, quietSince: tail.value?.modified ?? command.lastOutputAt, now: .now))
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            if command.kind != .scheduled, let lines = tail.value?.lines, !lines.isEmpty {
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                Text(lines.map(CommandText.plain).joined(separator: "\n"))
                    .font(TextStyle.code)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(Layout.Commands.tailLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Inset.well)
        .panel(.userBox)
        .task(id: command.isLive) {
            guard command.kind != .scheduled else { return }
            repeat {
                tail.value = await chat.commandTail(command.id, lines: Layout.Commands.tailLines)
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled && (chat.commands.command(command.id)?.isLive ?? false)
        }
    }
}

/// A small button with no fill until the pointer is over it ("Run in background").
private struct QuietSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietSmallButton(configuration: configuration)
    }
}

private struct QuietSmallButton: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hovered = Local(false)

    var body: some View {
        let lit = hovered.value || configuration.isPressed
        configuration.label
            .font(TextStyle.caption)
            .foregroundStyle(lit ? Theme.text : Theme.secondary)
            .padding(.horizontal, Space.lg)
            .frame(height: Size.smallButton)
            .background(lit ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
            .onHover { hovered.value = $0 }
    }
}

/// The words of a command's row.
enum CommandText {
    /// "12s", "8m 12s", "29h 39m", "3d 4h": two units at most.
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (d, h, m) = (s / 86_400, s % 86_400 / 3600, s % 3600 / 60)
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s % 60 > 0 ? "\(m)m \(s % 60)s" : "\(m)m" }
        return "\(s)s"
    }

    /// How a finished row ended, when it didn't simply succeed; nil for a success.
    static func word(_ state: ActiveCommand.State) -> String? {
        switch state {
        case .running, .completed: nil
        case .failed(let exit?): "exit \(exit)"
        case .failed(nil): "failed"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .timedOut: "timed out"
        case .ended: "ended"
        case .fired: "fired"
        case .deleted: "deleted"
        case .expired: "expired"
        }
    }

    /// "every 30 minutes · next 2:37 PM"; one-shot "at 2:37 PM".
    static func schedule(_ command: ActiveCommand) -> String {
        guard let schedule = command.schedule else { return "" }
        let next = schedule.next.map { time($0) }
        if !schedule.recurring { return next.map { "at \($0)" } ?? lowered(schedule.human ?? schedule.cron) }
        let every = lowered(schedule.human ?? schedule.cron)
        return command.isLive ? ([every] + [next.map { "next \($0)" }].compactMap { $0 }).joined(separator: " · ") : every
    }

    /// "shell, moved to the background at 2m · stopped by the agent · ~/work/cm · started 1:14 PM
    /// · pid 48211 · CPU 3% · 40 MB · no output for 2h".
    static func facts(_ command: ActiveCommand, quietSince: Date?, now: Date) -> String {
        var kind: String
        switch command.kind {
        case .shell: kind = "shell"
        case .foreground: kind = "foreground"
        case .monitor: kind = "monitor"
        case .scheduled: kind = command.schedule?.recurring == false ? "scheduled, once" : "scheduled"
        }
        if let moved = command.backgroundedAt, let start = command.startedAt {
            kind += ", moved to the background at \(age(moved.timeIntervalSince(start)))"
        }
        var parts = [kind]
        switch command.state {
        case .stopped(.user): parts.append("stopped by you")
        case .stopped(.agent): parts.append("stopped by the agent")
        case .deleted(.agent): parts.append("deleted by the agent")
        case .ended: parts.append("ended with the chat's CLI")
        default: break
        }
        if command.kind == .scheduled { parts.append(schedule(command)) }
        if let folder = command.folder { parts.append((folder as NSString).abbreviatingWithTildeInPath) }
        if let start = command.startedAt { parts.append("started \(day(start, now: now))") }
        if command.isLive, let process = command.process {
            if let pid = process.osPid { parts.append("pid \(pid)") }
            if let cpu = process.cpuPercent { parts.append("CPU \(Int(cpu.rounded()))%") }
            if let kb = process.memoryKB { parts.append(ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)) }
        }
        if command.isLive, command.kind != .scheduled, let quiet = quietSince, now.timeIntervalSince(quiet) >= 600 {
            parts.append("no output for \(age(now.timeIntervalSince(quiet)).split(separator: " ").first ?? "")")
        }
        return parts.joined(separator: " · ")
    }

    /// Escape sequences (colours, cursor moves) left out: the output shows as plain text.
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    }

    private static func lowered(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "1:14 PM"; "yesterday 8:02 AM"; "Oct 21, 8:02 AM".
    private static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time(date))"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

extension ActiveCommand.State {
    /// Exited non-zero: the one end in red.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// ">_ 2 still running after their agents ›" at the tree's foot: the one row commands add to
/// the map, only while some outlive their agents. Its click opens the Still running pane.
struct OutlivedLine: View {
    let count: Int
    let selected: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    static func text(_ count: Int) -> String {
        "\(count) still running after \(count == 1 ? "its agent" : "their agents")"
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                HStack(spacing: Space.md) {
                    Text(">_").font(Glyph.commandCue).foregroundStyle(Theme.accent)
                    Text(Self.text(count)).font(TextStyle.label.monospacedDigit()).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Glyph.chevron).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, Space.lg)
                .frame(height: Layout.AgentMap.groupRow * Zoom.shared.scale)
                .hoverFill(selected || hovered.value, selected ? Theme.surfaceHover : Theme.toolHover, radius: Radius.control)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .storyID(StoryID.AgentMap.outlived, press: { select() })
    }
}

/// The map's pane for the chat's own commands (its root row), or for those still running after
/// their agents (the foot line), each of those saying which agent it came from.
struct CommandsPane: View {
    let chat: Chat
    let pane: AgentMapState.Pane

    var body: some View {
        let rows = pane == .chat ? chat.commands.rows(of: .main) : (live: chat.commands.outlived, finished: [])
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(rows.live.count)
                Color.clear.frame(height: Space.xl)
                CommandsSection(chat: chat, rows: rows, showsOwner: pane == .outlived)
                if rows.live.isEmpty && rows.finished.isEmpty {
                    Text("Nothing runs in the background").font(TextStyle.body).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, Layout.Viewer.canvasSide)
        }
    }

    private func header(_ live: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                if pane == .chat { AgentNodeMark(kind: .root, radius: Layout.AgentMap.detailRadius) }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(pane == .chat ? chat.title : "Still running").font(TextStyle.title).foregroundStyle(Theme.text).lineLimit(1)
                    Text(pane == .chat ? "this chat" : "\(live) command\(live == 1 ? "" : "s") whose agent has ended")
                        .font(TextStyle.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.lg)
            // Room for the map's close button.
            .padding(.trailing, Size.iconButton + Space.md)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
    }
}
