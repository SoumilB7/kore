import HostClient
import src
import SwiftUI

/// A move's sheet: a small Kore popup in the middle of the window, accent corners, three check
/// lines and one button. A check that holds the move says what it waits for, with its choice
/// beside it; nothing spins over the view.
struct MoveSheetView: View {
    let sheet: MoveSheet

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(sheet.heading).font(Chrome.bodyMedium).foregroundStyle(Theme.text).lineLimit(2)
            VStack(alignment: .leading, spacing: Space.sm) {
                idle
                sync
                folder
            }
            if let line = sheet.line {
                Text(line).font(Chrome.label).foregroundStyle(Theme.danger).lineLimit(2).transition(.opacity)
            }
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button("Cancel") { sheet.onClose() }.smallButton()
                    .keyboardShortcut(.cancelAction)
                Button(sheet.moving ? (sheet.way == .bring ? "Bringing…" : "Sending…") : sheet.button) { sheet.onGo() }
                    .smallButton(prominent: true)
                    .disabled(!sheet.ready)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.lg)
        .frame(width: Size.Box.agentsWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .animation(Motion.fade, value: sheet.sync)
        .animation(Motion.fade, value: sheet.line)
        .animation(Motion.fade, value: sheet.busy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(sheet.heading))
    }

    private var idle: some View {
        HStack(spacing: Space.sm) {
            CheckMark(state: !sheet.working ? .done : sheet.waiting ? .waiting : sheet.busy == nil ? .held : .done)
            Text(sheet.idleLine).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if sheet.working, !sheet.moving, !sheet.waiting {
                Button("Stop and move") { sheet.busy = .stopFirst }.smallButton(prominent: sheet.busy == .stopFirst)
                Button("Move when it finishes") { sheet.busy = .waitFirst }.smallButton(prominent: sheet.busy == .waitFirst)
            }
        }
    }

    private var sync: some View {
        HStack(spacing: Space.sm) {
            switch sheet.sync {
            case .settled: CheckMark(state: .done)
            case .checking, .pending: CheckMark(state: .waiting)
            case .noPair, .failed: CheckMark(state: .held)
            }
            Text(sheet.syncLine).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if let ask = sheet.ask {
                Text(ask.question).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(2)
                Button(ask.start == .merge ? "Merge" : "Copy") { sheet.onAnswer() }.smallButton(prominent: true)
            } else if sheet.sync == .noPair, sheet.way == .bring {
                Button("Sync with a Mac folder…") { sheet.onPair() }.smallButton(prominent: true)
            }
        }
    }

    @ViewBuilder private var folder: some View {
        if let line = sheet.folderLine {
            HStack(spacing: Space.sm) {
                CheckMark(state: .done)
                Text(line).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// A check line's mark: ✓ when it holds, a soft pulsing point while it waits, a grey point when
/// it holds the move.
private struct CheckMark: View {
    enum Kind { case done, waiting, held }
    let state: Kind

    var body: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark").font(Chrome.label).foregroundStyle(Theme.accent)
            case .waiting:
                Circle().fill(Theme.accent).frame(width: Size.statusPoint, height: Size.statusPoint)
                    .pulse(low: Motion.blinkLow, period: Motion.blinkPeriod)
            case .held:
                Circle().fill(Theme.tertiary).frame(width: Size.statusPoint, height: Size.statusPoint)
            }
        }
        .frame(width: Space.lg)
        .transition(.opacity)
    }
}

/// Over a window while a move's sheet is open: the window dims a little under the sheet.
struct MoveSheetLayer: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            if let sheet = workspace.moveSheet {
                Theme.background.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { if !sheet.moving { sheet.onClose() } }
                    .transition(.opacity)
                MoveSheetView(sheet: sheet).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: workspace.moveSheet?.id)
    }
}

/// A replica's composer: one line saying where the chat lives, and its one action. Sends and
/// edits wait there; nothing here can change it.
struct ReplicaLine: View {
    let replica: ChatPlaces.Replica
    let sendBack: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.sm) {
            Circle().fill(Theme.tertiary).frame(width: Size.statusPoint, height: Size.statusPoint)
            Text(line).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            if let sendBack {
                Text("·").font(Chrome.label).foregroundStyle(Theme.tertiary)
                Button("Send back", action: sendBack).buttonStyle(.plain).font(Chrome.label).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Theme.surface, in: Capsule())
        .frame(maxWidth: .infinity)
        .help(replica.here ? "It runs on this Mac now · read-only here" : "It runs on \(replica.name) · read-only here")
    }

    private var line: String {
        if replica.moving { return "Moving…" }
        return replica.here ? "on this Mac" : "on \(replica.name) · read-only here"
    }
}
