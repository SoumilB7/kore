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
    /// The asks this run took, newest last: each runs once, whatever link hears how it ended.
    private static var asks: [(id: String, phone: UUID?, copy: Task<LinkActions.Outcome, Never>)] = []
    static let kept = 64
    /// What runs one (tests stand in).
    static var copy: @MainActor (CopyAsk, UUID?) async -> LinkActions.Outcome = { await once($0, phone: $1) }
    /// Why a phone may not copy to or from a box, by this Mac's records (`MacNet.refusesCopy`).
    static var refuses: @MainActor (_ phone: UUID?, _ box: UUID?, _ name: String) -> String? = { phone, box, name in
        guard let net = MacNet.shared else { return MacNet.notAllowed(name) }
        return net.refusesCopy(phone, box: box, name: name)
    }

    /// One ask's outcome: run now, or the one its id already started. Asked `again` with none
    /// known here (Kore quit meanwhile), it isn't run: the first may have been made.
    static func run(_ ask: CopyAsk, phone: UUID?) async -> LinkActions.Outcome {
        if let known = asks.first(where: { $0.id == ask.id && $0.phone == phone }) { return await known.copy.value }
        guard ask.again != true else { return .failed(.goneSession, "Kore doesn't know if that was copied · look there before copying again") }
        let copy = Task { await Self.copy(ask, phone) }
        asks.append((ask.id, phone, copy))
        if asks.count > kept { asks.removeFirst(asks.count - kept) }
        return await copy.value
    }

    private static func once(_ ask: CopyAsk, phone: UUID?) async -> LinkActions.Outcome {
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
        switch await ChatCopyAsk.run(from: from, to: to, provider: ask.provider, title: ask.title, phone: phone, refuses: { refuses(phone, $0, $1) }) {
        case .success: return .done
        case .failure(let failure): return .failed(.busy, failure.line)
        }
    }

    /// A window open here by its link id (a box's folder window here copies to and from the box).
    private static func window(_ id: String) -> Workspace? {
        LinkSnapshot.workspaces().first { LinkSnapshot.windowID($0) == id }
    }
}
