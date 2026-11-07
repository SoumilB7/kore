import AppKit
import SwiftUI

/// ⌘Q takes two: pressed once it says so and waits; pressed again soon, or held (the key's repeat
/// is the second press), it quits. Quit picked from the menu with the pointer, the Dock's Quit
/// and a logout are meant, and go straight through, as with no window open to say it in.
@MainActor @Observable
package final class QuitGuard {
    package static let shared = QuitGuard()

    /// The first press was just made: the notice shows.
    package private(set) var armed = false

    /// What quitting does; a storyline host records it.
    @ObservationIgnored package var terminate: () -> Void = { NSApp.terminate(nil) }
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private static let window: Duration = .seconds(2)

    package init() {}

    /// Quit Kore, from the menu.
    func menuItem() {
        press(byKey: NSApp.currentEvent?.type == .keyDown, hasWindow: NSApp.windows.contains { $0.isVisible && $0.canBecomeKey })
    }

    package func press(byKey: Bool, hasWindow: Bool) {
        guard byKey, hasWindow, !armed else {
            disarm()
            terminate()
            return
        }
        armed = true
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.armed = false
        }
    }

    package func disarm() {
        expiry?.cancel()
        expiry = nil
        armed = false
    }
}

/// The word the first ⌘Q leaves at the top of the window at the front.
struct QuitNotice: View {
    private var guardian: QuitGuard { .shared }
    @Environment(\.controlActiveState) private var active

    var body: some View {
        if guardian.armed, active == .key || StoryHost.installed {
            Text("Press ⌘Q again to quit")
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.text)
                .padding(Inset.floatingBar)
                .panel(.panel)
                .padding(.top, Space.xxxl)
                .allowsHitTesting(false)
                .storyID(StoryID.Titlebar.quitNotice)
                .transition(.opacity)
        }
    }
}
