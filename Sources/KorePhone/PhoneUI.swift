import KoreRemote
import KoreUI
import SwiftUI

/// The phone remote on the Mac: "/" → Phone opens its popup over the composer; the title row
/// has its button while it's on.
@MainActor
enum PhoneUI {
    static let entry = "phone"
    static let popupID = StoryID(.composer, "phone")
    static let buttonID = StoryID(.titlebar, "phone")
    static let switchID = popupID.part(.toggle)
    static let pairID = popupID.part(.add)
    static let codeFieldID = popupID.part(.field)
    static let allowID = popupID.part(.allow)
    static let denyID = popupID.part(.deny)
    static let cancelID = popupID.part(.cancel)
    static let activityID = popupID.part(.open)
    static let relayID = popupID.part(.share)
    static func rowID(_ phone: String) -> StoryID { StoryID(.composer, "phone.row", key: phone) }

    static func install() {
        let host = RemoteHost.shared
        KoreModules.commands.append(
            .init(
                command: { _ in
                    var command = SlashCommand(name: entry, description: "Use Kore from your phone", hint: "", kind: .kore, glyph: "iphone")
                    command.on = host.phone.isOn
                    command.moduleAliases = ["remote", "mobile", "pair"]
                    return command
                },
                perform: { chat in open(in: chat) }))
        KoreModules.popups.append(
            .init(
                isOpen: { host.phone.openIn == $0.id }, close: { _ in host.phone.openIn = nil },
                view: { chat, room in AnyView(PhonePopup(chat: chat, room: room, host: host, model: host.phone)) }))
        KoreModules.titleButtons.append { workspace, size in AnyView(PhoneButton(workspace: workspace, size: size, model: host.phone)) }
    }

    /// Kore Phone is the only module there is: taking it out empties them.
    static func uninstall() {
        KoreModules.commands.removeAll()
        KoreModules.popups.removeAll()
        KoreModules.titleButtons.removeAll()
    }

    static func open(in chat: Chat) {
        chat.openingModulePopup()
        RemoteHost.shared.phone.showingActivity = false
        RemoteHost.shared.phone.openIn = chat.id
    }
}

/// The title-row phone: only while Phone is on; faint with a phone on alerts only, lit while one
/// has full access. A click opens the popup in the window's chat.
struct PhoneButton: View {
    let workspace: Workspace
    let size: CGFloat
    let model: PhoneModel

    var body: some View {
        if model.isOn {
            ModuleTitleButton(systemImage: "iphone", help: model.line, lit: model.anyFull, size: size, id: PhoneUI.buttonID) {
                if let chat = workspace.activeTab.chat { PhoneUI.open(in: chat) }
            }
            .opacity(model.anyConnected ? 1 : ModuleStyle.off)
        }
    }
}
