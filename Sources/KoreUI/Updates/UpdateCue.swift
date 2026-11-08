import SwiftUI

/// The update cue (auto-update.html, C): at the end of the new-tab picker, only while this Kore
/// isn't the latest. The version, a hammer on hover for what a click does; the build's minutes
/// while it runs; a red point when it failed, its reason on hover, and a click tries again.
struct UpdateCue: View {
    @StateObject private var hovered = Local(false)

    var body: some View {
        let updater = Updater.shared
        switch updater.state {
        case .current:
            EmptyView()
        case .available(let version):
            button(version, help: "Kore \(version)", id: StoryID.NewTab.update) {
                Image(systemName: hovered.value ? "hammer" : "arrow.down.circle").foregroundStyle(Theme.accent)
            }
        case .installing(let version, let since):
            TimelineView(.periodic(from: since, by: 60)) { context in
                let minutes = Int(context.date.timeIntervalSince(since) / 60)
                let label = minutes > 0 ? "Building · \(minutes)m" : "Building"
                Text(label)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, Space.xxl)
                    .padding(.vertical, Space.md)
                    .help("Building \(version)")
            }
            .storyMark(StoryID.NewTab.update.part(.working))
        case .failed(let version, let why):
            button(version, help: why, id: StoryID.NewTab.update.part(.retry)) {
                Circle().fill(Theme.danger).frame(width: Layout.Timeline.dot, height: Layout.Timeline.dot)
            }
        }
    }

    private func button(_ version: String, help: String, id: StoryID, @ViewBuilder mark: () -> some View) -> some View {
        Button {
            Updater.shared.install()
        } label: {
            HStack(spacing: Space.sm) {
                mark()
                Text(version).font(TextStyle.body).foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.md)
            .background(hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
        .storyID(id)
    }
}
