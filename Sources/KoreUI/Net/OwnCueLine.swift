import HostClient
import SwiftUI

/// Kore's tailnet on the first page (the Welcome's This Mac and box tabs, a folder window's title
/// row): one quiet line while the device's isn't signed in, "Kore's tailnet: not signed in · Sign
/// in", its action right there; following a sign-in, how it goes, then "signed in as …" a moment.
/// Signed in, nothing (its hover in Devices says it).
struct OwnCueLine: View {
    /// The box's key; nil: this Mac.
    let box: String?
    let story: StoryID
    @StateObject private var hovered = Local(false)

    private var cue: OwnCue? {
        if let box { return Devices.shared.boxCue(box) }
        return Devices.shared.macCue()
    }

    var body: some View {
        if let cue {
            HStack(spacing: Space.xs) {
                Text(cue.line).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                if let action = cue.action {
                    Text("·").foregroundStyle(Theme.tertiary)
                    Button(action.title) { act(cue) }
                        .buttonStyle(.plain)
                        .foregroundStyle(hovered.value ? Theme.text : Theme.accent)
                        .onHover { hovered.value = $0 }
                        .fixedSize()
                        .storyID(story.part(.use), press: { act(cue) })
                }
            }
            .font(Chrome.label)
            .storyID(story)
        }
    }

    private func act(_ cue: OwnCue) { Devices.shared.cueAction(cue, box: box) }
}

extension StoryID.Net {
    /// The first page's Kore's tailnet line, by device (a box's key, or this Mac's), and its action.
    package static func welcomeCue(_ box: String?) -> StoryID { StoryID(.welcome, "net.cue", key: box ?? "this-mac") }
    package static func titleCue(_ box: String?) -> StoryID { StoryID(.titlebar, "net.cue", key: box ?? "this-mac") }
}
