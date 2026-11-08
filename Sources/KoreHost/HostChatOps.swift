import Foundation
import KoreCore
import LinkProtocol
import src

/// Link 1.9: a chat's own operations from a client's control kinds (`chat.rename`, `chat.fork`, …),
/// as a Mac window's menus and buttons do them, on the box's own chat. Each was allowed by
/// `LinkPolicy.checkBox` first. A full grant driving the chat does the same through `chat.call`.
extension HostDaemon {
    func chatOp(_ kind: ControlKind, _ args: ControlArgs, id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        let done = LinkMessage.Result(id: id, ok: true)
        if kind == .arsenalStopAll {
            let on = chats.filter { $0.arsenal != nil }
            for hc in on { arsenalSaid(nil, hc) }
            broadcast(chats: on)
            return done
        }
        guard let hc = args.chatId.flatMap(chat) else { return fail(.goneChat, "No such chat on this box.") }
        defer { broadcast(chats: [hc]) }
        switch kind {
        case .chatRename:
            let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            hc.setTitle(title)
            // A running CLI takes it as its own title too.
            hc.chat?.rename(title)
        case .chatSetAutoCompact:
            hc.setAutoCompact(args.at)
        case .chatSetDraft:
            hc.setDraft(args.text ?? "")
        case .chatSetArsenal:
            arsenalSaid(args.tier == "off" ? nil : args.tier, hc)
        case .chatCancelContinue:
            hc.chat?.cancelContinue()
        case .chatRetry:
            guard let chat = hc.chat else { return fail(.busy, "Nothing to retry there.") }
            if let turn = args.turnId {
                guard chat.transcriptView.retryableTurn == turn, !chat.isBusy else { return fail(.busy, "Nothing to retry there.") }
                chat.retryTurn(turn)
            } else {
                guard chat.connection == .stalled else { return fail(.busy, "Nothing to retry there.") }
                chat.retryStalled()
            }
        case .chatContinue:
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            guard !chat.isBusy else { return fail(.busy, "No turn to continue.") }
            chat.continueTurn()
        case .chatSendAtReset:
            guard let chat = hc.chat, chat.limitReset != nil, chat.sendsAtReset == nil, !chat.isBusy else {
                return fail(.busy, "There's no limit reset to send at.")
            }
            // As the composer's ring does, without keeping the text in the box chat's composer.
            let kept = (chat.command, chat.draft, chat.attachments)
            (chat.command, chat.draft, chat.attachments) = (nil, args.text ?? "", [])
            chat.sendAtReset()
            let went = chat.sendsAtReset != nil
            (chat.command, chat.draft, chat.attachments) = kept
            if !went { return fail(.busy, "There's no limit reset to send at.") }
        case .chatCompact:
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            Task {
                // A chat whose CLI is stopped starts it (its session) first.
                await chat.startOnce()
                guard chat.canCompact else { return reply(fail(.busy, "The chat can't compact right now.")) }
                chat.compact(instructions: args.instructions ?? "")
                reply(done)
            }
            return nil
        case .chatFork:
            guard let chat = live(hc) else { return fail(.busy, "Too many CLIs are running on this box.") }
            Task { reply(await fork(hc, chat, args, id: id)) }
            return nil
        default:
            return fail(.invalid, "Not taken here.")
        }
        return done
    }

    /// A fork of the chat as a Mac's message actions make one: from a user message (that message
    /// in the fork's draft, not sent), after an answer (`after`), or from its end (`after` with no
    /// message). It's a new chat in the same folder, "<title> (fork)", the same model, mode and
    /// effort.
    private func fork(_ hc: HostChat, _ chat: Chat, _ args: ControlArgs, id: String) async -> LinkMessage.Result {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        await chat.startOnce()
        guard chat.sessionId != nil else { return fail(.busy, "This chat can't be forked yet.") }
        let after = args.after == true
        let start: ForkStart?
        var draft = ""
        if let entryId = args.entryId {
            guard let entry = entry(entryId, in: hc, chat) else { return fail(.invalid, "No message to fork from there.") }
            if after {
                start = await chat.forkStart(after: entry)
            } else {
                start = await chat.forkStart(entry)
                draft = entry.text
            }
        } else {
            start = try? await chat.connect().forkAtEnd()
        }
        guard let start else { return fail(.busy, "Couldn't fork it: the chat says why.") }
        let from: (from: String, at: String)? = if case .pending(let point) = start { (point.from, point.at) } else { nil }
        guard
            let made = newChat(
                folder: hc.record.folder, provider: hc.record.provider, modelId: chat.controls.modelId ?? chat.launchModel, fork: from,
                title: "\(chat.title) (fork)", mode: chat.controls.mode, effort: chat.controls.effort)
        else { return fail(.goneFolder, "That folder isn't on this box.") }
        if !draft.isEmpty {
            made.setDraft(draft)
            broadcast(chats: [made])
        }
        return .init(id: id, ok: true, chatId: made.id, windowId: Self.windowID(made.record.folder))
    }

    /// A message by the id a client holds: the live chat's, else the message with the same words
    /// (a CLI started again names its history anew).
    private func entry(_ id: String, in hc: HostChat, _ chat: Chat) -> TranscriptLog.Entry? {
        let entries = chat.transcriptView.entries
        if let entry = entries.first(where: { $0.id.uuidString == id }) { return entry }
        // Only a log a watching client already has read in: nothing is read into memory for it.
        guard hc.txFollowed, let sent = hc.entries.first(where: { $0.id == id }), let text = sent.text else { return nil }
        let kind: TranscriptLog.Entry.Kind = sent.kind == .user ? .user : .answer
        return entries.last { $0.kind == kind && $0.text == text }
    }
}
