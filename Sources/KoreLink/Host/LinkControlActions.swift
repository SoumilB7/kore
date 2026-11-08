import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// A 1.2 command carried out in Kore (`z-docs/link-protocol.md` §11), after the policy allows it
/// against the run's grant and the chat as it is now. Each runs Kore's own control for it; what
/// it opens opens in the background, except `chat.select`.
@MainActor
enum LinkControlActions {
    typealias Outcome = LinkActions.Outcome

    static func apply(_ kind: ControlKind, _ args: ControlArgs, control: LinkControlLevel, files: [URL] = []) async -> Outcome {
        let chats = LinkSnapshot.chatsByID()
        let chat = args.chatId.flatMap { chats[$0] }
        if case .deny(let code, let message) = LinkPolicy.check(.control(kind, args), chat.map(LinkSnapshot.facts), control: control) {
            return .failed(code, message)
        }
        if kind.onChat {
            guard let chat else { return .failed(.goneChat, "That chat isn't open in Kore any more.") }
            return await onChat(kind, args, chat, files: files)
        }
        if kind.onAccount { return await onAccount(kind, args) }
        if kind == .arsenalStopAll {
            Arsenal.shared.stopAll()
            return .done
        }
        return await onWindow(kind, args, files: files)
    }

    // MARK: Chats

    private static func onChat(_ kind: ControlKind, _ args: ControlArgs, _ chat: Chat, files: [URL]) async -> Outcome {
        let workspace = LinkSnapshot.workspace(of: chat)
        switch kind {
        case .chatRename:
            chat.linkRename(args.title ?? "")
        case .chatClose:
            guard let workspace, let tab = LinkSnapshot.tab(of: chat, in: workspace) else { return .failed(.goneChat, "That chat has no tab of its own.") }
            switch workspace.linkClose(tab, force: args.force == true) {
            case .closed: break
            case .asks: return .failed(.confirmClose, "It's working; closing stops it. Send again with force to close.")
            case .gone: return .failed(.goneChat, "That chat isn't open in Kore any more.")
            }
        case .chatSelect:
            guard let workspace, let tab = LinkSnapshot.tab(of: chat, in: workspace) ?? LinkSnapshot.board(of: chat, in: workspace) else {
                return .failed(.goneChat, "That chat isn't open in Kore any more.")
            }
            workspace.linkSelect(tab)
        case .chatSetModel:
            guard chat.linkSetModel(args.modelId ?? "") else { return .failed(.invalid, "This chat doesn't offer that model.") }
        case .chatSetEffort:
            guard chat.linkSetEffort(args.level ?? "") else { return .failed(.invalid, "This chat's model doesn't offer that effort.") }
        case .chatSetFast:
            guard chat.linkSetFast(args.on == true) else { return .failed(.busy, "Fast mode isn't offered here now.") }
        case .chatCompact:
            guard chat.linkCompact(args.instructions ?? "") else { return .failed(.busy, "The chat can't compact right now.") }
        case .chatSetAutoCompact:
            chat.linkSetAutoCompact(args.at)
        case .chatFork:
            guard let workspace, chat.linkCanFork else { return .failed(.busy, "This chat can't be forked yet.") }
            guard let fork = await workspace.linkFork(chat, entryId: args.entryId ?? "", after: args.after == true) else {
                return .failed(.invalid, "No message to fork from there.")
            }
            return Outcome(ok: true, newChat: fork, newWindowId: LinkSnapshot.windowID(workspace))
        case .chatRetry:
            guard chat.linkRetry(args.turnId) else { return .failed(.busy, "Nothing to retry there.") }
        case .chatContinue:
            guard chat.linkContinue() else { return .failed(.busy, "No turn to continue.") }
        case .chatSendAtReset:
            guard chat.linkSendAtReset(args.text ?? "", files: files) else { return .failed(.busy, "There's no limit reset to send at.") }
        case .chatCancelContinue:
            chat.linkCancelContinue()
        case .chatSetDraft:
            chat.linkSetDraft(args.text ?? "")
        case .chatSetArsenal:
            return setArsenal(args.tier, chat)
        default:
            return .failed(.invalid, "Kore doesn't know that command.")
        }
        return .done
    }

    /// `chat.setArsenal`, by the tiers popup's path. The policy refused Full, unknown tiers and a
    /// chat that can't have it; Arsenal checks the last two again.
    static func setArsenal(_ id: String?, _ chat: Chat) -> Outcome {
        let tier = ArsenalTier(rawValue: id ?? "")
        guard id == "off" || tier?.built == true else { return .failed(.invalid, "Arsenal has no such tier.") }
        guard Arsenal.shared.linkSet(tier, chat) else { return .failed(.busy, Arsenal.unavailable(chat) ?? "Arsenal can't be on here now.") }
        return .done
    }

    // MARK: Windows, tabs, groups, boards, history

    // MARK: Accounts

    /// A CLI's account, as the Account popup does it. A sign-in started here opens nothing on the
    /// Mac; one that only the Mac can finish is refused `denied.mac`.
    private static func onAccount(_ kind: ControlKind, _ args: ControlArgs) async -> Outcome {
        if kind == .accountPrivacy {
            AccountStore.linkSetPrivacy(args.on == true)
            return .done
        }
        guard let provider = args.provider, Registry.provider(provider) != nil else {
            return .failed(.invalid, "Kore doesn't know that CLI.")
        }
        let store = AccountStore.shared
        let outcome: AccountStore.LinkOutcome
        switch kind {
        case .accountSignIn:
            let aim: AccountStore.LinkAim =
                switch args.aim {
                case "new": .new
                case "login": .login(args.login ?? "")
                default: .active
                }
            outcome = store.linkSignIn(provider, method: args.method, aim: aim)
        case .accountSubmit:
            outcome = await store.linkSubmit(provider, serial: args.serial ?? -1, input: args.input ?? "")
        case .accountCancel:
            outcome = store.linkCancel(provider)
        case .accountSwitch:
            outcome = store.linkSwitch(provider, to: args.login ?? "")
        case .accountRemove:
            outcome = store.linkRemove(provider, args.login ?? "")
        case .accountSignOut:
            outcome = store.linkSignOut(provider)
        case .accountRefresh:
            await store.refresh(provider)
            outcome = .ok
        default:
            outcome = .invalid("Kore doesn't know that command.")
        }
        switch outcome {
        case .ok: return .done
        case .busy: return .failed(.busyAccount, "A sign-in, switch or sign-out is under way for that CLI.")
        case .mac: return .failed(.deniedMac, "That sign-in needs the Mac.")
        case .goneLogin: return .failed(.goneLogin, "That login isn't there any more.")
        case .goneFlow: return .failed(.goneFlow, "No sign-in is under way.")
        case .staleFlow: return .failed(.staleFlow, "The sign-in moved on; look again.")
        case .invalid(let message): return .failed(.invalid, message)
        case .failed(let message): return .failed(.busy, message)
        }
    }

    private static func onWindow(_ kind: ControlKind, _ args: ControlArgs, files: [URL]) async -> Outcome {
        switch kind {
        case .windowOpen:
            guard let id = args.recentId, let folder = LinkSnapshot.recent(id) else { return .failed(.goneFolder, "That folder isn't in Kore's recents.") }
            AppModel.shared?.openFolder(folder)
            return Outcome(ok: true, newWindowId: StableID.of(folder.path, prefix: "w_"))
        case .windowReopen:
            guard let app = AppModel.shared, app.linkCanReopenWindow else { return .failed(.busy, "No closed window to reopen.") }
            app.linkReopenWindow()
            return .done
        case .macStayAwake:
            return LinkAwake.choose(args.mode ?? "") ? .done : .failed(.invalid, "Stay awake has no such mode.")
        default: break
        }
        guard let workspace = LinkSnapshot.workspaces().first(where: { LinkSnapshot.windowID($0) == args.windowId }) else {
            return .failed(.goneWindow, "That window isn't open in Kore any more.")
        }
        let tabs = Dictionary(workspace.tabs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        switch kind {
        case .chatNew:
            var board: ChatTab?
            var section: UUID?
            if let boardTabId = args.place?.boardTabId {
                guard let tab = tabs[boardTabId], tab.board != nil else { return .failed(.goneTab, "That board isn't open any more.") }
                board = tab
                section = args.place?.sectionId.flatMap(UUID.init(uuidString:))
            }
            let group = args.place?.groupId.flatMap(UUID.init(uuidString:))
            if let group, workspace.tabGroups.group(group) == nil { return .failed(.goneGroup, "That group is gone.") }
            guard
                let chat = workspace.linkStartChat(
                    provider: args.provider ?? "", model: args.modelId, board: board, section: section, group: group)
            else { return .failed(.invalid, "No such CLI.") }
            return Outcome(ok: true, newChat: chat, newWindowId: LinkSnapshot.windowID(workspace))
        case .windowClose:
            switch workspace.linkCloseWindow(force: args.force == true) {
            case .closed: return .done
            case .asks: return .failed(.confirmClose, "A chat in it is working; closing stops it. Send again with force.")
            case .gone: return .failed(.goneWindow, "That window isn't open in Kore any more.")
            }
        case .tabMove:
            guard let tab = args.tabId.flatMap({ tabs[$0] }) else { return .failed(.goneTab, "That tab is gone.") }
            workspace.linkMoveTab(tab, to: args.index ?? 0)
        case .tabReopen:
            guard workspace.linkCanReopenTab else { return .failed(.busy, "No closed tab to reopen.") }
            workspace.linkReopenTab()
        case .groupSet:
            guard let tab = args.tabId.flatMap({ tabs[$0] }) else { return .failed(.goneTab, "That tab is gone.") }
            switch args.groupId {
            case nil: workspace.removeFromGroup(tab)
            case "new": _ = workspace.newGroup(with: tab)
            case let id?:
                guard let group = UUID(uuidString: id), workspace.tabGroups.group(group) != nil else { return .failed(.goneGroup, "That group is gone.") }
                workspace.add(tab, to: group)
            }
        case .groupEdit:
            guard let group = args.groupId.flatMap(UUID.init(uuidString:)), let current = workspace.tabGroups.group(group) else {
                return .failed(.goneGroup, "That group is gone.")
            }
            if let name = args.name { workspace.rename(group: group, to: String(name.prefix(LinkPolicy.maxTitle))) }
            if let color = args.color {
                guard let picked = TabGroupColor(rawValue: color) else { return .failed(.invalid, "No such colour.") }
                workspace.recolor(group: group, picked)
            }
            if let folded = args.folded, folded != current.folded { workspace.toggleFold(group) }
        case .groupUngroup:
            guard let group = args.groupId.flatMap(UUID.init(uuidString:)), workspace.tabGroups.group(group) != nil else {
                return .failed(.goneGroup, "That group is gone.")
            }
            workspace.ungroup(group)
        case .groupClose:
            guard let group = args.groupId.flatMap(UUID.init(uuidString:)), workspace.tabGroups.group(group) != nil else {
                return .failed(.goneGroup, "That group is gone.")
            }
            let members = workspace.tabs.filter { workspace.tabGroups.member[$0.id] == group }
            if args.force != true, members.contains(where: { $0.chat?.isBusy == true }) {
                return .failed(.confirmClose, "A chat in it is working; closing stops it. Send again with force.")
            }
            workspace.closeGroup(group)
        case .boardNew:
            guard let tab = workspace.linkNewBoard() else { return .failed(.busy, "Kore couldn't make a board.") }
            return Outcome(ok: true, newWindowId: LinkSnapshot.windowID(workspace), newTabId: tab.id.uuidString)
        case .boardAttach:
            guard let board = args.boardTabId.flatMap({ tabs[$0] }), board.board != nil else { return .failed(.goneTab, "That board isn't open any more.") }
            guard let chat = args.chatId.flatMap({ LinkSnapshot.chatsByID()[$0] }), let tab = LinkSnapshot.tab(of: chat, in: workspace) else {
                return .failed(.goneChat, "That chat isn't a tab in this window.")
            }
            let section: UUID? = args.sectionId == "new" ? nil : args.sectionId.flatMap(UUID.init(uuidString:))
            workspace.linkAttach(tab, to: board, section: section)
        case .boardDetach:
            guard let board = args.boardTabId.flatMap({ tabs[$0] }), board.board != nil else { return .failed(.goneTab, "That board isn't open any more.") }
            guard let chat = args.chatId.flatMap({ LinkSnapshot.chatsByID()[$0] }), workspace.linkDetach(chat, from: board, toTab: args.toTab == true) else {
                return .failed(.goneChat, "That chat isn't on that board.")
            }
        case .boardSection:
            guard let board = args.boardTabId.flatMap({ tabs[$0] }), board.board != nil,
                let section = args.sectionId.flatMap(UUID.init(uuidString:))
            else { return .failed(.goneTab, "That board or section is gone.") }
            if args.remove == true {
                workspace.linkRemoveSection(section, from: board)
            } else if let name = args.name {
                workspace.linkRenameSection(section, on: board, to: String(name.prefix(LinkPolicy.maxTitle)))
            } else {
                return .failed(.invalid, "One change at a time: a name, or remove.")
            }
        case .historyOpen:
            guard let id = args.sessionId, let chat = workspace.linkOpenSession(id) else { return .failed(.goneSession, "That chat isn't in this folder's history.") }
            return Outcome(ok: true, newChat: chat, newWindowId: LinkSnapshot.windowID(workspace))
        case .historyRename:
            guard let id = args.sessionId, await workspace.linkRenameSession(id, to: args.title ?? "") else {
                return .failed(.goneSession, "That chat isn't in this folder's history.")
            }
        case .historyArchive:
            guard let id = args.sessionId, await workspace.linkArchiveSession(id, args.on ?? true) else {
                return .failed(.goneSession, "That chat isn't in this folder's history.")
            }
        default:
            return .failed(.invalid, "Kore doesn't know that command.")
        }
        return .done
    }
}
