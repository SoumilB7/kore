import AppKit
import SwiftUI

/// Open Folder… and the recent folders: ↑ ↓ light one (as the pointer does) and Return opens it.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The one lit recent folder: the pointer's, or the keys'.
    @StateObject private var lit = Local<Int?>(nil)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    var body: some View {
        VStack(spacing: Layout.Welcome.sectionGap) {
            VStack(spacing: Space.sm) {
                BrandMark(height: Layout.Welcome.markHeight)
                    .padding(.bottom, Space.lg)
                Text("Kore")
                    .font(Chrome.display)
                    .foregroundStyle(Theme.text)
                Text("Open a folder to start")
                    .font(Chrome.body)
                    .foregroundStyle(Theme.secondary)
            }

            Button {
                if let folder = app.chooseFolder() { open(folder) }
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .buttonStyle(SubtleButtonStyle(prominent: true))

            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Recent")
                        .font(Chrome.captionMedium)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.xxs)
                    ForEach(Array(app.recents.enumerated()), id: \.element) { index, folder in
                        RecentRow(folder: folder, lit: lit.value == index) { open(folder) }
                            .highlightRow(StoryID.Welcome.recent(folder.path), lit: lit.value == index) { lit.value = index }
                    }
                }
                .frame(width: Layout.Welcome.contentWidth)
            }

            if let problem = app.cliProblem {
                Text(problem)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(width: Layout.Welcome.contentWidth)
            }
            if let signedOut = app.signedOutLine {
                Text(signedOut)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: Layout.Welcome.contentWidth)
            }
        }
        .padding(.vertical, Layout.Welcome.paddingV)
        .padding(.horizontal, Layout.Welcome.paddingH)
        .frame(width: Layout.Welcome.width)
        .frame(minHeight: Layout.Welcome.minHeight)
        // The window takes the content's full height (with .contentSize), so nothing is cut off.
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowReader { window.value = $0 })
        .onAppear {
            if monitor.value == nil { monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key($0) } }
            app.welcomeTakesKeys = true
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
            app.welcomeTakesKeys = false
        }
        .task {
            // A dev snapshot of this window when no folder is opened.
            if let folder = DevSnapshot.openFolder { open(folder) } else { DevSnapshot.captureIfRequested() }
            await app.checkCLI()
        }
    }

    private func open(_ folder: URL) {
        app.open(folder, openWindow: openWindow, dismissWindow: dismissWindow)
    }

    /// ↑ ↓ through the recent folders, stopping at the ends (from none, the first or the last),
    /// Return opens the lit one. This window's keys only.
    private func key(_ event: NSEvent) -> NSEvent? {
        let recents = app.recents
        guard let window = window.value, event.window === window, !recents.isEmpty,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return event }
        switch event.keyCode {
        case 125, 126:
            let step = event.keyCode == 125 ? 1 : -1
            lit.value = lit.value.map { min(max($0 + step, 0), recents.count - 1) } ?? (step > 0 ? 0 : recents.count - 1)
            PointerGate.keyed()
        case 36, 76:
            guard let index = lit.value, recents.indices.contains(index) else { return event }
            open(recents[index])
        default:
            return event
        }
        return nil
    }
}

private struct RecentRow: View {
    let folder: URL
    let lit: Bool
    let action: @MainActor @Sendable () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.lg) {
                Image(systemName: "folder")
                    .font(Chrome.label)
                    .foregroundStyle(Theme.secondary)
                Text(folder.lastPathComponent)
                    .font(Chrome.bodyMedium)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Space.xl)
                Text(folder.deletingLastPathComponent().abbreviatedPath)
                    .font(Chrome.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(Inset.row)
            .hoverFill(lit, Theme.Row.selected(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.path)
        .storyID(StoryID.Welcome.recent(folder.path), press: action)
    }
}
