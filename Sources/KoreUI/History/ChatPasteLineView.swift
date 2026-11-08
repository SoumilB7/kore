import SwiftUI

/// A chat paste at the top of the window: the one ask before a cut of a working chat ("Stop and
/// move"), and, while the window's explorer (which has it at its foot) is closed, the transfer
/// bar's chat pastes: "Copying chat to mybox · 1.2 MB of 3.4 MB", Cancel, a failure with Retry.
struct ChatPasteLineView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: Space.sm) {
            if let line = workspace.chatPaste {
                HStack(spacing: Space.sm) {
                    Circle().fill(Theme.accent).frame(width: Size.statusPoint, height: Size.statusPoint)
                    Text(line.text).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    if let ask = line.ask {
                        Button("Cancel") { workspace.chatPaste = nil }.smallButton()
                        Button(ask) { line.go() }.smallButton(prominent: true)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .panel(.panel)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
            if !explorerShowsBar, !TransferProgress.shared.shown(under: nil, window: workspace.transferKey).isEmpty {
                TransferBar(root: nil, window: workspace.transferKey)
                    .frame(width: 360)
                    .panel(.panel)
                    .transition(.opacity)
            }
        }
        .padding(.top, Space.md)
        .animation(Motion.fade, value: workspace.chatPaste?.id)
    }

    /// The explorer's foot has the window's bar already.
    private var explorerShowsBar: Bool { workspace.explorerOpen && workspace.sidebar != .search }
}
