import Foundation
import HostClient
import KoreUI
import LinkProtocol
import src

/// `chat.copyVia` (cap "copyVia") on this Mac: the ends a phone named, found here (a chat by its id, a past
/// session in a window's History, a window), then the copy run as Paste Chat runs it
/// (`ChatCopyAsk`). A box's ends are found by `ChatCopyAsk` over the box's link.
@MainActor
enum LinkCopyVia {
    static func run(_ ask: CopyAsk) async -> LinkActions.Outcome {
        let from: ChatCopyAsk.From
        if let device = ask.from.device {
            from = .box(device: device, windowId: ask.from.windowId, id: ask.from.chatId ?? ask.from.sessionId ?? "")
        } else if let chatId = ask.from.chatId {
            guard let chat = LinkSnapshot.chatsByID()[chatId] else { return .failed(.goneChat, "That chat isn't open in Kore any more.") }
            from = .chat(chat, in: LinkSnapshot.workspace(of: chat))
        } else {
            guard let window = window(ask.from.windowId), let session = ask.from.sessionId else {
                return .failed(.goneWindow, "That window isn't open in Kore any more.")
            }
            from = .history(window, session: session)
        }
        let to: ChatCopyAsk.To
        if let device = ask.to.device {
            to = .box(device: device, windowId: ask.to.windowId)
        } else {
            guard let window = window(ask.to.windowId) else { return .failed(.goneWindow, "That window isn't open in Kore any more.") }
            to = .mac(window)
        }
        switch await ChatCopyAsk.run(from: from, to: to, provider: ask.provider, title: ask.title) {
        case .success: return .done
        case .failure(let failure): return .failed(.busy, failure.line)
        }
    }

    /// A window open here by its link id (a box's folder window here copies to and from the box).
    private static func window(_ id: String) -> Workspace? {
        LinkSnapshot.workspaces().first { LinkSnapshot.windowID($0) == id }
    }
}
