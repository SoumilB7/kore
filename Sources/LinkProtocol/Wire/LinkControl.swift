import Foundation
import src

// KoreLink 1.2 (`z-docs/link-protocol.md` §11): what a companion granted full control for this run
// may also read and do. Without the grant every command and read here is answered
// `denied.control`, and none of the state below is sent: the link behaves exactly as 1.1.

/// The run's grant, from Kore's card: Allow (standard) or Allow with full control (full).
package enum LinkControlLevel: String, LenientEnum { case standard, full, unknown }

/// A 1.2 command's type on the wire.
package enum ControlKind: String, Sendable, CaseIterable {
    // Step 1: chats.
    case chatRename = "chat.rename"
    case chatClose = "chat.close"
    case chatSelect = "chat.select"
    case chatSetModel = "chat.setModel"
    case chatSetEffort = "chat.setEffort"
    case chatSetFast = "chat.setFast"
    case chatCompact = "chat.compact"
    case chatSetAutoCompact = "chat.setAutoCompact"
    case chatFork = "chat.fork"
    case chatRetry = "chat.retry"
    case chatContinue = "chat.continue"
    case chatSendAtReset = "chat.sendAtReset"
    case chatCancelContinue = "chat.cancelContinue"
    /// `chat.new` with a model or a place (a plain one stays 1.0's `chat.new`).
    case chatNew = "chat.new"
    // Step 2: tabs, groups, boards, windows, history.
    case chatSetDraft = "chat.setDraft"
    case tabMove = "tab.move"
    case tabReopen = "tab.reopen"
    case groupSet = "group.set"
    case groupEdit = "group.edit"
    case groupUngroup = "group.ungroup"
    case groupClose = "group.close"
    case boardNew = "board.new"
    case boardAttach = "board.attach"
    case boardDetach = "board.detach"
    case boardSection = "board.section"
    case windowOpen = "window.open"
    case windowReopen = "window.reopen"
    case windowClose = "window.close"
    case historyOpen = "history.open"
    case historyRename = "history.rename"
    case historyArchive = "history.archive"
    case macStayAwake = "mac.stayAwake"
    // Steps 3–4: accounts. There is no `account.useKey`: no message carries a key.
    case accountSignIn = "account.signIn"
    case accountSubmit = "account.submit"
    case accountCancel = "account.cancel"
    case accountSwitch = "account.switch"
    case accountRemove = "account.remove"
    case accountSignOut = "account.signOut"
    case accountRefresh = "account.refresh"
    case accountPrivacy = "account.privacy"
    // 1.3: Arsenal, a chat's agent-control tier, and Stop agent control.
    case chatSetArsenal = "chat.setArsenal"
    case arsenalStopAll = "arsenal.stopAll"
    // 1.4: a box's folders (its windows).
    case foldersList = "folders.list"
    case folderAdd = "folder.add"
    /// 1.4: `gh` signs in to github.com on the box, by its device code.
    case authGh = "auth.gh"
    /// 1.4: a served folder's changes, pushed to this client as `sync.changed` while it's linked.
    case syncWatch = "sync.watch"
    case syncUnwatch = "sync.unwatch"
    /// 1.7: a box's files, read for the Mac's explorer and folder browser (`LinkFiles.swift`).
    case fsList = "fs.list"
    case fsRead = "fs.read"
    case fsMkdir = "fs.mkdir"
    /// 1.8: editing a served folder's files, finding in them, and watching open folders.
    case fsWrite = "fs.write"
    case fsCreate = "fs.create"
    case fsRename = "fs.rename"
    case fsDelete = "fs.delete"
    case fsSearch = "fs.search"
    case fsWatch = "fs.watch"
    /// 1.11: an entry copied within the served folders, and an entry's files and bytes counted
    /// (what a copy across devices checks before its source goes).
    case fsCopy = "fs.copy"
    case fsCount = "fs.count"
    /// 1.11: a running `fs.copy` stopped (its partial copy removed), named by its command's id.
    case fsCancel = "fs.cancel"
    /// 1.10: a chat moves between the box and a Mac (`LinkMoves.swift`), and the sync says when
    /// both ends have settled.
    case chatRelease = "chat.release"
    case chatAdopt = "chat.adopt"
    case chatMirror = "chat.mirror"
    case syncFlush = "sync.flush"

    /// A file command (1.7, 1.8): answered with a `FilesResult`, full grants only.
    package var onFiles: Bool { rawValue.hasPrefix("fs.") }

    /// It acts on a CLI's account.
    package var onAccount: Bool { rawValue.hasPrefix("account.") }

    /// It acts on one chat, named by `chatId`.
    package var onChat: Bool {
        switch self {
        case .chatRename, .chatClose, .chatSelect, .chatSetModel, .chatSetEffort, .chatSetFast, .chatCompact, .chatSetAutoCompact,
            .chatFork, .chatRetry, .chatContinue, .chatSendAtReset, .chatCancelContinue, .chatSetDraft, .chatSetArsenal:
            true
        default: false
        }
    }
}

/// Where `chat.new` puts the chat: a board (and a section of it), or a tab group.
package struct ChatPlace: Codable, Sendable, Equatable {
    package var boardTabId: String?
    package var sectionId: String?
    package var groupId: String?
    package init(boardTabId: String? = nil, sectionId: String? = nil, groupId: String? = nil) {
        self.boardTabId = boardTabId
        self.sectionId = sectionId
        self.groupId = groupId
    }
}

/// A 1.2 command's fields. Each command reads the ones its row in §11 names; the rest are absent.
package struct ControlArgs: Codable, Sendable, Equatable {
    package var chatId: String?
    package var windowId: String?
    package var title: String?
    package var force: Bool?
    package var modelId: String?
    package var level: String?
    package var on: Bool?
    package var instructions: String?
    /// `chat.setAutoCompact`: a percentage; absent or null turns it off.
    package var at: Int?
    package var entryId: String?
    package var after: Bool?
    package var turnId: String?
    package var text: String?
    package var blobs: [String]?
    package var rev: Int?
    package var sourceId: String?
    package var provider: String?
    package var place: ChatPlace?
    package var tabId: String?
    package var index: Int?
    /// `group.set`: a group's id, "new", or null to take the tab out of its group.
    package var groupId: String?
    package var name: String?
    package var color: String?
    package var folded: Bool?
    package var boardTabId: String?
    package var sectionId: String?
    package var toTab: Bool?
    package var swatch: String?
    package var mergeInto: String?
    package var remove: Bool?
    package var recentId: String?
    package var sessionId: String?
    package var mode: String?
    /// `account.*`: the sign-in method, its aim ("active", "new" or "login"), a login's id
    /// ("main" for main), the flow's serial, and the code the user typed from the manual page.
    package var method: String?
    package var aim: String?
    package var login: String?
    package var serial: Int?
    package var input: String?
    /// `chat.setArsenal` (1.3): a built tier's id, or "off".
    package var tier: String?
    /// 1.4 (a box): `chat.new`'s folder in place of `windowId`; `folder.add`'s absolute path.
    package var folder: String?
    package var path: String?
    /// 1.7: `fs.list` lists dotfiles too; `fs.read` reads at most this many bytes.
    package var hidden: Bool?
    package var max: Int?
    /// 1.8: `fs.write`'s bytes (base64), or the upload holding them, and what it last read;
    /// `fs.create`'s kind; `fs.rename`'s ends; `fs.search`'s root and query; `fs.watch`'s folders.
    package var data: String?
    package var blob: String?
    package var base: FileStamp?
    package var dir: Bool?
    package var from: String?
    package var to: String?
    package var root: String?
    package var query: String?
    package var folders: [String]?
    /// 1.10: a move's phase (`prepare`, `commit`, `abort`), the owner's gen it expects, its id,
    /// stopping a working chat to move it, the sending side's folders, the holder's name, and a
    /// mirror's first seq and events.
    package var phase: String?
    package var gen: Int?
    package var moveId: String?
    package var stop: Bool?
    package var host: String?
    package var seq: Int?
    package var events: MirrorItems?
    /// 1.11: `fs.cancel`'s copy: the `fs.copy` command's id.
    package var copyId: String?

    package init(
        chatId: String? = nil, windowId: String? = nil, title: String? = nil, force: Bool? = nil, modelId: String? = nil,
        level: String? = nil, on: Bool? = nil, instructions: String? = nil, at: Int? = nil, entryId: String? = nil,
        after: Bool? = nil, turnId: String? = nil, text: String? = nil, blobs: [String]? = nil, rev: Int? = nil,
        sourceId: String? = nil, provider: String? = nil, place: ChatPlace? = nil, tabId: String? = nil, index: Int? = nil,
        groupId: String? = nil, name: String? = nil, color: String? = nil, folded: Bool? = nil, boardTabId: String? = nil,
        sectionId: String? = nil, toTab: Bool? = nil, swatch: String? = nil, mergeInto: String? = nil, remove: Bool? = nil,
        recentId: String? = nil, sessionId: String? = nil, mode: String? = nil, method: String? = nil, aim: String? = nil,
        login: String? = nil, serial: Int? = nil, input: String? = nil, tier: String? = nil,
        folder: String? = nil, path: String? = nil, hidden: Bool? = nil, max: Int? = nil, data: String? = nil, blob: String? = nil,
        base: FileStamp? = nil, dir: Bool? = nil, from: String? = nil, to: String? = nil, root: String? = nil, query: String? = nil,
        folders: [String]? = nil, phase: String? = nil, gen: Int? = nil, moveId: String? = nil, stop: Bool? = nil, host: String? = nil,
        seq: Int? = nil, events: MirrorItems? = nil
    ) {
        self.phase = phase
        self.gen = gen
        self.moveId = moveId
        self.stop = stop
        self.host = host
        self.seq = seq
        self.events = events
        self.data = data
        self.blob = blob
        self.base = base
        self.dir = dir
        self.from = from
        self.to = to
        self.root = root
        self.query = query
        self.folders = folders
        self.chatId = chatId
        self.windowId = windowId
        self.title = title
        self.force = force
        self.modelId = modelId
        self.level = level
        self.on = on
        self.instructions = instructions
        self.at = at
        self.entryId = entryId
        self.after = after
        self.turnId = turnId
        self.text = text
        self.blobs = blobs
        self.rev = rev
        self.sourceId = sourceId
        self.provider = provider
        self.place = place
        self.tabId = tabId
        self.index = index
        self.groupId = groupId
        self.name = name
        self.color = color
        self.folded = folded
        self.boardTabId = boardTabId
        self.sectionId = sectionId
        self.toTab = toTab
        self.swatch = swatch
        self.mergeInto = mergeInto
        self.remove = remove
        self.recentId = recentId
        self.sessionId = sessionId
        self.mode = mode
        self.method = method
        self.aim = aim
        self.login = login
        self.serial = serial
        self.input = input
        self.tier = tier
        self.folder = folder
        self.path = path
        self.hidden = hidden
        self.max = max
    }
}

// MARK: - State (sent only with full control)

/// A chat's controls, as its composer shows them.
package struct ChatControls: Codable, Sendable, Equatable {
    package enum Remote: String, LenientEnum { case off, on, changing, unavailable, unknown }
    package var modelId: String?
    package var effort: String?
    package var fast: Bool?
    package var fastOffered: Bool
    package var planAllow: Bool
    /// How full the context is, 0–100; absent until the CLI says.
    package var contextPct: Int?
    package var autoCompactAt: Int?
    package var compacting: Bool
    package var remote: Remote
    /// 1.4 (a box): the tokens in context and the window they're measured against, as the CLI
    /// last said; absent until it says.
    package var contextUsed: Int?
    package var contextWindow: Int?
    /// 1.9 (a box): how many times the chat's kept draft changed (`setDraft`); absent before the
    /// first. The draft itself is read with the `draft` call, only when this moves.
    package var draftRev: Int?

    package init(
        modelId: String?, effort: String?, fast: Bool?, fastOffered: Bool, planAllow: Bool, contextPct: Int?, autoCompactAt: Int?,
        compacting: Bool, remote: Remote, contextUsed: Int? = nil, contextWindow: Int? = nil
    ) {
        self.modelId = modelId
        self.effort = effort
        self.fast = fast
        self.fastOffered = fastOffered
        self.planAllow = planAllow
        self.contextPct = contextPct
        self.autoCompactAt = autoCompactAt
        self.compacting = compacting
        self.remote = remote
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
    }
}

/// What a chat offers to get going again. Times are ms since 1970.
package struct ChatRescue: Codable, Sendable, Equatable {
    package enum Connection: String, LenientEnum { case ok, stalled, offline, unknown }
    package var connection: Connection
    /// The ended turn `chat.retry` with a `turnId` retries.
    package var retryTurn: String?
    /// A turn the Mac's sleep cut off: `chat.continue`.
    package var slept: Bool?
    package var limitReset: Int64?
    package var continuesAt: Int64?
    package var sendsAtReset: Bool?

    package init(
        connection: Connection, retryTurn: String? = nil, slept: Bool? = nil, limitReset: Int64? = nil, continuesAt: Int64? = nil,
        sendsAtReset: Bool? = nil
    ) {
        self.connection = connection
        self.retryTurn = retryTurn
        self.slept = slept
        self.limitReset = limitReset
        self.continuesAt = continuesAt
        self.sendsAtReset = sendsAtReset
    }
}

/// A window's tab groups.
package struct LinkGroup: Codable, Sendable, Equatable {
    package var id: String
    package var name: String
    package var color: String
    package var folded: Bool
    package init(id: String, name: String, color: String, folded: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.folded = folded
    }
}

/// The Mac's side: recent folders by opaque id (never a path the link could name), whether a
/// closed window can come back, Stay awake, and (1.3) Arsenal's built tiers in order.
package struct MacState: Codable, Sendable, Equatable {
    package struct Recent: Codable, Sendable, Equatable {
        package var id: String
        package var name: String
        /// Relative to `~`.
        package var path: String
        package init(id: String, name: String, path: String) {
            self.id = id
            self.name = name
            self.path = path
        }
    }

    package struct StayAwake: Codable, Sendable, Equatable {
        package var mode: String
        package var on: Bool
        package init(mode: String, on: Bool) {
            self.mode = mode
            self.on = on
        }
    }

    package var recents: [Recent]
    package var canReopenWindow: Bool
    package var stayAwake: StayAwake?
    package var arsenalTiers: [String]?
    package init(recents: [Recent], canReopenWindow: Bool, stayAwake: StayAwake?, arsenalTiers: [String]? = nil) {
        self.recents = recents
        self.canReopenWindow = canReopenWindow
        self.stayAwake = stayAwake
        self.arsenalTiers = arsenalTiers
    }
}

/// A CLI's account (1.2 steps 3–4): who it's signed in as, its logins, how it can sign in, and
/// the sign-in under way. Emails are masked while Kore's privacy mode is on.
package struct LinkAccountState: Codable, Sendable, Equatable {
    package struct Login: Codable, Sendable, Equatable {
        package var id: String
        package var email: String?
        package var workspace: String?
        package var active: Bool
        package var signedOut: Bool
        package var duplicate: Bool
        package init(id: String, email: String?, workspace: String?, active: Bool, signedOut: Bool, duplicate: Bool) {
            self.id = id
            self.email = email
            self.workspace = workspace
            self.active = active
            self.signedOut = signedOut
            self.duplicate = duplicate
        }
    }

    package struct Method: Codable, Sendable, Equatable {
        package enum Where: String, LenientEnum { case link, mac, unknown }
        package var id: String
        package var label: String
        package var hint: String?
        package var group: String?
        package var kind: String
        package var `where`: Where
        package init(id: String, label: String, hint: String?, group: String?, kind: String, where place: Where) {
            self.id = id
            self.label = label
            self.hint = hint
            self.group = group
            self.kind = kind
            self.where = place
        }
    }

    /// A sign-in under way. One the Mac started carries only its step; one the link started also
    /// its page (never a callback on the Mac) and, for a device code, the code.
    package struct Flow: Codable, Sendable, Equatable {
        package var serial: Int
        package var method: String?
        package var startedByLink: Bool
        package var switching: Bool
        package var step: String
        package var url: String?
        package var code: String?
        package var takesPaste: Bool
        package var error: String?
        package init(
            serial: Int, method: String?, startedByLink: Bool, switching: Bool, step: String, url: String?, code: String?,
            takesPaste: Bool, error: String?
        ) {
            self.serial = serial
            self.method = method
            self.startedByLink = startedByLink
            self.switching = switching
            self.step = step
            self.url = url
            self.code = code
            self.takesPaste = takesPaste
            self.error = error
        }
    }

    package var status: String
    package var email: String?
    package var plan: String?
    package var workspace: String?
    package var method: String?
    package var privacy: Bool
    package var logins: [Login]
    package var methods: [Method]
    package var workingChats: Int
    package var flow: Flow?
    package init(
        status: String, email: String?, plan: String?, workspace: String?, method: String?, privacy: Bool, logins: [Login],
        methods: [Method], workingChats: Int, flow: Flow?
    ) {
        self.status = status
        self.email = email
        self.plan = plan
        self.workspace = workspace
        self.method = method
        self.privacy = privacy
        self.logins = logins
        self.methods = methods
        self.workingChats = workingChats
        self.flow = flow
    }
}

/// A CLI's models (1.2 step 1) and account (steps 3–4).
package struct CLIState: Codable, Sendable, Equatable {
    package struct Model: Codable, Sendable, Equatable {
        package var id: String
        package var name: String
        package var efforts: [String]
        package var fast: Bool
        package var auto: Bool
        package init(id: String, name: String, efforts: [String], fast: Bool, auto: Bool) {
            self.id = id
            self.name = name
            self.efforts = efforts
            self.fast = fast
            self.auto = auto
        }
    }

    package var provider: String
    package var models: [Model]
    package var effortScale: [String]
    package var account: LinkAccountState?
    package init(provider: String, models: [Model], effortScale: [String], account: LinkAccountState? = nil) {
        self.provider = provider
        self.models = models
        self.effortScale = effortScale
        self.account = account
    }
}

/// What a snapshot or delta adds with full control.
package struct LinkExtras: Sendable, Equatable {
    package var mac: MacState?
    package var clis: [CLIState]?
    /// 1.4 (a box): whether `gh` is signed in to github.com there.
    package var ghSignedIn: Bool?
    package init(mac: MacState? = nil, clis: [CLIState]? = nil, ghSignedIn: Bool? = nil) {
        self.mac = mac
        self.clis = clis
        self.ghSignedIn = ghSignedIn
    }
}

// MARK: - Reads

/// One past chat in a window's history.
package struct HistorySession: Codable, Sendable, Equatable {
    package var id: String
    package var provider: String
    package var title: String
    /// ms since 1970.
    package var updatedAt: Int64
    package var archived: Bool
    package var open: Bool
    package init(id: String, provider: String, title: String, updatedAt: Int64, archived: Bool, open: Bool) {
        self.id = id
        self.provider = provider
        self.title = title
        self.updatedAt = updatedAt
        self.archived = archived
        self.open = open
    }
}
