import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                BrandMark(height: 56)
                    .padding(.bottom, 10)
                Text("Kore")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Open a folder to start")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }

            Button {
                if let folder = app.chooseFolder() { open(folder) }
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .buttonStyle(SubtleButtonStyle(prominent: true))

            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    ForEach(app.recents, id: \.self) { folder in
                        RecentRow(folder: folder) { open(folder) }
                    }
                }
                .frame(width: 380)
            }

            if let problem = app.cliProblem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(width: 380)
            }
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 40)
        .frame(width: 480)
        .frame(minHeight: 360)
        // The window takes the content's full height (with .contentSize), so nothing is cut off.
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // A dev snapshot of this window when no folder is opened.
            if let folder = DevSnapshot.openFolder { open(folder) } else { DevSnapshot.captureIfRequested() }
            await app.checkCLI()
        }
    }

    private func open(_ folder: URL) {
        app.open(folder, openWindow: openWindow, dismissWindow: dismissWindow)
    }
}

private struct RecentRow: View {
    let folder: URL
    let action: () -> Void
    @StateObject private var hovering = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Text(folder.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                Text(folder.deletingLastPathComponent().abbreviatedPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help(folder.path)
    }
}
