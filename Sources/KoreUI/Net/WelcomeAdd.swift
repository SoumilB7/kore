import AppKit
import HostClient
import SwiftUI

/// The Welcome switcher's "+" (frame D1): the add-box choices (`BoxAddChoicesList`, the same
/// rows Devices' "Add a box" shows) in a popup of their own.
struct WelcomeAddList: View {
    /// Use SSH…: the switcher's field.
    let useSSH: @MainActor () -> Void
    /// New box…: its popup.
    let newBox: @MainActor () -> Void
    /// A box claimed: the Welcome stands on it.
    let ready: @MainActor (String) -> Void

    var body: some View {
        BoxAddChoicesList(net: Devices.shared.picture().net, useSSH: useSSH, newBox: newBox, ready: ready) { NetPopupHost.shared.close() }
            .padding(.vertical, Space.xs + 1)
            .frame(width: Size.Net.listWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .panel(.panel)
            .cornerMarks(Theme.cornerOption)
            .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
            .storyID(StoryID.Net.welcomeAdd)
    }
}

/// A box's claim: its card (frame B, with the device code), then on Allow the box is this Mac's
/// and the Welcome stands on it.
@MainActor
enum WelcomeClaim {
    /// Nil once the card is up; else why the box can't be claimed from here.
    static func ask(_ peer: ClaimPeer, ready: @escaping @MainActor (String) -> Void) async -> String? {
        guard let claims = Devices.shared.claims else { return "Turn KoreNet on first" }
        switch await claims.claim(peer) {
        case .failure(let refusal): return refusal.line
        case .success(let info):
            DeviceCardPanel.show(info) { allow in
                guard allow else { return }
                Task { @MainActor in
                    if let key = await claims.allow(peer) {
                        Devices.shared.changed()
                        ready(key)
                    }
                }
            }
            return nil
        }
    }
}

/// New box… (frame D1 2) from the Welcome: its title and the Add device window's countdown over
/// `NewBoxBody`.
struct NewBoxPopup: View {
    let ready: @MainActor (String) -> Void

    var body: some View {
        let picture = Devices.shared.picture()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                Text("New box").font(Theme.Net.line).fontWeight(.medium).foregroundStyle(Theme.text)
                if let until = picture.addUntil { Countdown(until: until) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xs)
            .frame(minHeight: Size.Net.header)
            NewBoxBody(ready: ready) { NetPopupHost.shared.close() }
        }
        .padding(.vertical, Space.xs + 1)
        .frame(width: Size.Net.sheetWidth - Space.md, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .storyID(StoryID.Net.newBoxPopup)
    }
}
