import SwiftUI

/// What a module installed at launch adds to Kore: entries among Kore's own in "/", and buttons
/// in each window's title row. Kore itself installs none; Kore Phone installs the phone remote's.
@MainActor
package enum KoreModules {
    /// A Kore entry in "/": its line in the menu (kind `.kore`), and what picking it does in a chat.
    package struct Command {
        package let command: @MainActor (Chat) -> SlashCommand
        package let perform: @MainActor (Chat) -> Void

        package init(command: @escaping @MainActor (Chat) -> SlashCommand, perform: @escaping @MainActor (Chat) -> Void) {
            self.command = command
            self.perform = perform
        }
    }

    package static var commands: [Command] = []
    /// A title-row button, given the window's workspace and the row's control size.
    package static var titleButtons: [@MainActor (Workspace, CGFloat) -> AnyView] = []

    /// The module entry a pick in "/" names, if any.
    static func command(named name: String, in chat: Chat) -> Command? {
        commands.first { $0.command(chat).name == name }
    }
}

/// The modules' title-row buttons, in the order they were installed.
struct ModuleTitleButtons: View {
    let workspace: Workspace
    let size: CGFloat

    var body: some View {
        ForEach(KoreModules.titleButtons.indices, id: \.self) { KoreModules.titleButtons[$0](workspace, size) }
    }
}
