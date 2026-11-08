import SwiftUI

/// Devices as a window's leading pane, in the explorer's place: one or the other is open (the
/// network icon and Kore ▸ Devices… toggle it). The popup's list on the window's ground, under a
/// 34pt header, its rows scrolling. Docked beside the content from 700pt wide, floating from the
/// leading edge below that. Made only while it's open; meanwhile KoreNet's bus is held for the window.
struct DevicesSidebar: View {
    /// The bus hold's key: one per window (`key`).
    let holdKey: String
    let floating: Bool

    var body: some View {
        DevicesPopup(pane: true, holdKey: holdKey)
            .background(floating ? Theme.surface : Theme.background)
    }

    /// The bus hold's key for a window.
    static func key(_ workspace: Workspace) -> String { "devices:\(ObjectIdentifier(workspace))" }

    /// Lists showing per hold key. A pane moving between docked and floating appears again before
    /// or after it goes: the bus stays held throughout.
    private static var shown: [String: Int] = [:]

    static func hold(_ key: String, by change: Int) {
        let count = max(0, (shown[key] ?? 0) + change)
        shown[key] = count == 0 ? nil : count
        Devices.shared.net?.hold(key, count > 0)
    }
}

/// The Devices pane's sash, on its trailing side as the explorer's is: dragging right widens it; a
/// double-click gives it back its own width.
struct DevicesSash: View {
    @Binding var width: CGFloat
    let dragging: (Bool) -> Void

    var body: some View {
        PaneSash(width: $width, range: Layout.Devices.minWidth...Layout.Devices.maxWidth, dragging: dragging) {
            width = Layout.Devices.width
        }
        .storyID(StoryID.Net.sash)
    }
}

extension StoryID.Net {
    /// Devices as the window's leading pane (in the explorer's place), and its sash.
    package static let panel = StoryID(.titlebar, "net.panel")
    package static let sash = StoryID(.titlebar, "net.sash")
}
