import Foundation

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

    /// It acts on one chat, named by `chatId`.
    package var onChat: Bool {
        switch self {
        case .chatRename, .chatClose, .chatSelect, .chatSetModel, .chatSetEffort, .chatSetFast, .chatCompact, .chatSetAutoCompact,
            .chatFork, .chatRetry, .chatContinue, .chatSendAtReset, .chatCancelContinue, .chatSetDraft:
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

    package init(
        chatId: String? = nil, windowId: String? = nil, title: String? = nil, force: Bool? = nil, modelId: String? = nil,
        level: String? = nil, on: Bool? = nil, instructions: String? = nil, at: Int? = nil, entryId: String? = nil,
        after: Bool? = nil, turnId: String? = nil, text: String? = nil, blobs: [String]? = nil, rev: Int? = nil,
        sourceId: String? = nil, provider: String? = nil, place: ChatPlace? = nil, tabId: String? = nil, index: Int? = nil,
        groupId: String? = nil, name: String? = nil, color: String? = nil, folded: Bool? = nil, boardTabId: String? = nil,
        sectionId: String? = nil, toTab: Bool? = nil, swatch: String? = nil, mergeInto: String? = nil, remove: Bool? = nil,
        recentId: String? = nil, sessionId: String? = nil, mode: String? = nil
    ) {
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

    package init(
        modelId: String?, effort: String?, fast: Bool?, fastOffered: Bool, planAllow: Bool, contextPct: Int?, autoCompactAt: Int?,
        compacting: Bool, remote: Remote
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
/// closed window can come back, and Stay awake.
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
    package init(recents: [Recent], canReopenWindow: Bool, stayAwake: StayAwake?) {
        self.recents = recents
        self.canReopenWindow = canReopenWindow
        self.stayAwake = stayAwake
    }
}

/// A CLI's models (1.2 step 1; its account comes in a later step).
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
    package init(provider: String, models: [Model], effortScale: [String]) {
        self.provider = provider
        self.models = models
        self.effortScale = effortScale
    }
}

/// What a snapshot or delta adds with full control.
package struct LinkExtras: Sendable, Equatable {
    package var mac: MacState?
    package var clis: [CLIState]?
    package init(mac: MacState? = nil, clis: [CLIState]? = nil) {
        self.mac = mac
        self.clis = clis
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
