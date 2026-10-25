import AppKit
import SwiftUI

/// A key the folder window's tabs take, as a Mac app's tabs do (Safari, Terminal): ⌘W closes
/// the tab, ⌃⇥ and ⌃⇧⇥ show the next and previous, ⌘1–8 that tab and ⌘9 the last; and ⌘,
/// opens the chat's Account popup, Kore's settings being in the / menu.
enum TabKey: Equatable {
    case close, next, previous, number(Int), account

    /// The tab key a key press is, if any.
    static func of(_ characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TabKey? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        // The Tab key, whatever ⇧ makes of its character.
        if keyCode == 48 {
            switch flags {
            case .control: return .next
            case [.control, .shift]: return .previous
            default: return nil
            }
        }
        guard flags == .command, let key = characters?.lowercased() else { return nil }
        if key == "w" { return .close }
        if key == "," { return .account }
        if let n = Int(key), (1...9).contains(n) { return .number(n) }
        return nil
    }
}

/// The File menu shows the tab keys; this takes them first, for its own window. The menu runs a
/// command for the focused window's workspace only, which a window that isn't key never is (a
/// storyline's), and a monitor sees the key before any view or menu, as the editor's keys do.
struct TabKeys: ViewModifier {
    let workspace: Workspace
    @StateObject private var monitor = Held<Any?>(nil)

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor.value == nil else { return }
                let workspace = workspace
                monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window = workspace.window, event.window === window,
                        let key = TabKey.of(event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags)
                    else { return event }
                    switch key {
                    // Held down, ⌘W closes one tab: a repeat could answer its own question.
                    case .close: if !event.isARepeat { workspace.perform(.closeTab) }
                    case .next: workspace.perform(.nextTab)
                    case .previous: workspace.perform(.previousTab)
                    case .number(let n): workspace.selectNumber(n)
                    case .account: workspace.openAccount()
                    }
                    return nil
                }
            }
            .onDisappear {
                if let value = monitor.value { NSEvent.removeMonitor(value) }
                monitor.value = nil
            }
    }
}
