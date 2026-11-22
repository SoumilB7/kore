import AgentTools
import Foundation
import KoreCore
import LinkProtocol
import src

// A box's own Arsenal: kore-host answers a box chat's `kore_app` calls about the box's own chats
// itself, by the chat's tier as the Mac last said it (kept in its record), with the Mac connected
// or not. The rules are the agent channel's (`ArsenalRules`, the `Chat` rules in `src`, the same
// words and limits); only what needs the Mac goes over the link: its chats, its windows and files,
// asks between chats, and anything that reads both devices at once while the Mac is there (the
// chat list, every chat's cards, `whoami`), whose ids are the Mac's. The Mac's view of the box's
// chats follows what happens here through the link's own events.

/// What a box's Arsenal keeps between calls: each chat's limits, the chats it opened, its calls in
/// flight and its waits. Nothing is kept on disk but the tier.
/// A call's refusal line, as a `Result`'s failure.
struct Refused: Error {
    let line: Data
    init(_ line: Data) { self.line = line }
}

@MainActor
final class HostArsenal {
    var commands: [String: RateLimiter] = [:]
    var sends: [String: RateLimiter] = [:]
    var news: [String: RateLimiter] = [:]
    var made: [String: [String]] = [:]
    var inFlight: [String: Int] = [:]
    var waits: [Wait] = []

    struct Wait {
        let token = UUID()
        let caller: String
        let target: String
        let done: (Data) -> Void
    }
}

extension HostDaemon {
    /// The box's name in a chat's folder, as the Mac's list shows a box's ("mybox:~/app").
    static var boxName: String { String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "box") }

    static func shownFolder(_ path: String) -> String { boxName + ":" + LinkProjection.homeRelative(path) }

    /// The chat's tier as kept (off when it never had one).
    func tier(_ hc: HostChat) -> AgentTier { hc.arsenal.flatMap(AgentTier.init(rawValue:)) ?? .off }

    // MARK: Which side answers

    /// Whether the box answers this call itself: one about its own chats, or any call while no Mac
    /// is connected that the box can answer (a refusal included). `mac`: a Mac is connected now.
    func answersHere(_ hc: HostChat, _ name: String, _ args: AgentTools.Object, mac: Bool) -> Bool {
        let tier = tier(hc)
        // Off here: the Mac decides while it's connected (its tier may be newer); else refused here.
        guard tier != .off else { return !mac }
        guard let tool = AgentTools.tool(name, box: true) else { return true }
        // Above the tier: refused here, in the same words.
        if ArsenalRules.refusal(tool: name, tier: tier, box: true) != nil { return true }
        let chat = args["chat"] as? String
        switch tool.command {
        case AgentCommand.caps.name: return true
        case AgentCommand.whoami.name, AgentCommand.chats.name: return !mac
        case AgentCommand.cards.name: return chat == nil ? !mac : resolvesHere(hc, chat)
        case AgentCommand.wait.name: return args["ask"] != nil ? false : resolvesHere(hc, chat)
        case AgentCommand.send.name:
            // A folder named: one of this box's, its chats there; another's, or none of its chats
            // (a past chat to wake, through the Mac's box window), the Mac's.
            guard let folder = args["folder"] as? String else { return resolvesHere(hc, chat) }
            guard let path = historyFolder(folder, of: hc) else { return !mac }
            return resolvesHere(hc, chat, in: path)
        case AgentCommand.show.name, AgentCommand.read.name, AgentCommand.stop.name, AgentCommand.answer.name:
            return resolvesHere(hc, chat)
        case AgentCommand.close.name: return resolvesHere(hc, chat, byID: true)
        case _ where AgentTools.ownCommands.contains(tool.command): return resolvesHere(hc, chat ?? ".")
        case AgentCommand.history.name: return (args["folder"] as? String).map { historyFolder($0, of: hc) != nil } ?? true
        case AgentCommand.new.name:
            // Another folder (Act device): one this box serves here; any other the Mac's, as its
            // windows open folders.
            if let folder = args["folder"] as? String { return tier < .device || historyFolder(folder, of: hc) != nil || !mac }
            return (args["place"] as? String).map { $0 != "mac" } ?? true
        // Forks, opens from History, asks and their replies, files and tabs: the Mac's.
        default: return false
        }
    }

    /// `ref` names something on the box: one of its chats, several (answered here as ambiguous),
    /// or nothing well-formed. A ref no box chat has may be one of the Mac's.
    private func resolvesHere(_ hc: HostChat, _ ref: String?, byID: Bool = false, in folder: String? = nil) -> Bool {
        guard let ref, !ref.isEmpty else { return true }
        let titled = readable(hc, in: folder).map { (id: $0.id, title: $0.title) }
        if byID {
            if case .none = AgentRefs.resolveID(ref, chats: titled) { return false }
            return true
        }
        if case .none = AgentRefs.resolve(ref, chats: titled, own: hc.id) { return false }
        return true
    }

    // MARK: A call

    /// One call answered here, as the agent channel answers a box chat's: a channel line, its
    /// command's result or refusal.
    func arsenalCall(_ hc: HostChat, _ name: String, _ given: AgentTools.Object) async -> Data {
        let tier = tier(hc)
        if let (code, text) = ArsenalRules.refusal(tool: name, tier: tier, box: true, folder: given["folder"] != nil) { return Self.failed(code, text) }
        guard let tool = AgentTools.tool(name, box: true) else { return Self.failed(.unknownCommand, ArsenalRules.message(.unknownCommand)) }
        guard boxArsenal.commands[hc.id, default: RateLimiter(limit: ArsenalRules.perMinute, per: 60)].take() else {
            return Self.failed(.rateLimited, ArsenalRules.message(.rateLimited))
        }
        let args = decoded(AgentTools.arguments(tool, given))
        let line = await run(hc, tool.command, args)
        HostJournal.note("tool", ["chat": hc.id, "cmd": tool.command, "result": Self.code(line) ?? "ok"])
        return line
    }

    private func decoded(_ args: AgentTools.Object) -> AgentArgs {
        (try? JSONSerialization.data(withJSONObject: args)).flatMap { try? JSONDecoder().decode(AgentArgs.self, from: $0) } ?? AgentArgs()
    }

    static func failed(_ code: AgentCode, _ message: String) -> Data {
        ArsenalRules.encode(AgentResult<AgentEmpty>(id: "box", ok: false, code: code, message: message))
    }

    static func ok(_ data: some Encodable & Sendable) -> Data { ArsenalRules.encode(AgentResult(id: "box", ok: true, data: data)) }

    private static func code(_ line: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["code"] as? String
    }

    private func run(_ hc: HostChat, _ name: String, _ args: AgentArgs) async -> Data {
        switch name {
        case AgentCommand.whoami.name:
            return Self.ok(AgentWhoami(caller: callerInfo(hc), tier: tier(hc)))
        case AgentCommand.caps.name:
            return Self.ok(AgentCaps(tier: tier(hc), commands: AgentCommand.allowed(tier(hc)).map(\.name)))
        case AgentCommand.chats.name:
            return Self.ok(AgentChats(chats: readable(hc).map { agentChat($0, own: hc.id) }))
        case AgentCommand.cards.name:
            let shown: [HostChat]
            if args.chat != nil {
                switch resolve(args.chat, hc) {
                case .failure(let refused): return refused.line
                case .success(let found): shown = [found]
                }
            } else {
                shown = readable(hc)
            }
            return Self.ok(AgentCards(cards: shown.flatMap(agentCards)))
        case AgentCommand.show.name:
            return resolved(args.chat, hc) { Self.ok(self.detail($0, own: hc.id)) }
        case AgentCommand.read.name:
            return resolved(args.chat, hc) { Self.ok(Self.rows($0, last: args.last, before: args.before)) }
        case AgentCommand.history.name:
            return await historyList(hc, args)
        case AgentCommand.wait.name:
            return await wait(hc, args)
        case AgentCommand.options.name, AgentCommand.rename.name, AgentCommand.model.name, AgentCommand.effort.name,
            AgentCommand.mode.name, AgentCommand.fast.name, AgentCommand.compact.name:
            return change(hc, name, args)
        case AgentCommand.new.name:
            return newChat(hc, args)
        case AgentCommand.send.name:
            return send(hc, args)
        case AgentCommand.stop.name:
            return other(args.chat, hc) { target in
                let running = target.running
                target.chat?.stop()
                return Self.ok(AgentDone(chat: target.id, message: running ? "Stopped." : "Nothing was running."))
            }
        case AgentCommand.answer.name:
            return other(args.chat, hc) { target in
                guard let card = args.card, card.utf8.count <= 256, (args.answers ?? []).allSatisfy({ $0.utf8.count <= 4096 }), (args.answers ?? []).count <= 16 else {
                    return Self.failed(.invalid, "Name the card, and give an answer per question or deny.")
                }
                guard let chat = target.chat else { return Self.failed(.refused, "That card was answered or withdrawn.") }
                let outcome = chat.arsenalAnswer(card, args.answers ?? [], deny: args.deny ?? false, allow: args.allow ?? false, always: args.always ?? false, by: hc.chat, tier: ArsenalTier(rawValue: self.tier(hc).rawValue))
                self.broadcast(chats: [target])
                return Self.done(outcome, target)
            }
        case AgentCommand.close.name:
            return close(hc, args)
        default:
            return Self.failed(.unknownCommand, ArsenalRules.message(.unknownCommand))
        }
    }

    static func done(_ outcome: Result<String, ArsenalRefusal>, _ hc: HostChat) -> Data {
        switch outcome {
        case .success(let message): ok(AgentDone(chat: hc.id, message: message))
        case .failure(let refusal): failed(.refused, refusal.message)
        }
    }

    // MARK: Chats

    /// The box's open chats a caller may read, as the Mac's rule: those in its own folder, and those
    /// whose own Arsenal is on.
    func readable(_ hc: HostChat) -> [HostChat] {
        chats.filter { $0.record.folder == hc.record.folder || $0.arsenal != nil }
    }

    /// `readable`, and with `folder` only that folder's (`chat.send --folder`).
    func readable(_ hc: HostChat, in folder: String?) -> [HostChat] {
        guard let folder else { return readable(hc) }
        return readable(hc).filter { Self.standard($0.record.folder) == Self.standard(folder) }
    }

    private func callerInfo(_ hc: HostChat) -> AgentCallerInfo {
        AgentCallerInfo(class: "chat", chat: hc.id, short: AgentRefs.short(hc.id), title: Self.title(hc.title))
    }

    static func title(_ text: String) -> String { LinkProjection.capped(text, LinkProjection.inputCap).text }

    static func state(_ meta: ChatMeta) -> String {
        switch meta.state {
        case .needsYou: "needs-you"
        case .failed: "failed"
        case .stuck: "stuck"
        case .working: "working"
        case .idle, .unknown: "idle"
        }
    }

    func agentChat(_ hc: HostChat, own: String?) -> AgentChat {
        let meta = HostMeta.meta(hc)
        let mode = HostMeta.modeID(hc)
        return AgentChat(
            id: hc.id, short: AgentRefs.short(hc.id), title: Self.title(hc.title), provider: hc.provider.id, folder: Self.shownFolder(hc.record.folder),
            window: URL(fileURLWithPath: hc.record.folder).lastPathComponent, state: Self.state(meta), mode: mode,
            modeLabel: hc.provider.modes.first { $0.id == mode }?.label, planOn: meta.mode.planOn, model: meta.model, queued: meta.queued,
            cards: meta.cards.count, own: hc.id == own ? true : nil)
    }

    private func detail(_ hc: HostChat, own: String?) -> AgentChatDetail {
        let controls = HostMeta.controls(hc)
        hc.caughtUp()
        let context = controls.contextUsed.map { AgentChatDetail.Context(used: $0, window: controls.contextWindow, pct: controls.contextPct) }
        return AgentChatDetail(
            chat: agentChat(hc, own: own), session: hc.record.session, effort: controls.effort, context: context, rows: hc.entries.count,
            pending: agentCards(hc))
    }

    /// As the Mac caps a card's parts (`AgentReads.cards`).
    static let bodyCap = 4 * 1024

    func agentCards(_ hc: HostChat) -> [AgentCard] {
        HostMeta.cards(hc).map { card in
            AgentCard(
                chat: hc.id, chatShort: AgentRefs.short(hc.id), chatTitle: Self.title(hc.title), id: card.id, kind: card.kind.rawValue,
                title: Self.title(card.title), detail: card.detail.map { LinkProjection.capped($0, Self.bodyCap).text },
                body: card.body.map { LinkProjection.capped($0, Self.bodyCap).text },
                questions: card.questions?.prefix(16).map { q in
                    .init(text: LinkProjection.capped(q.text, Self.bodyCap).text, options: q.options.prefix(32).map { Self.title($0.label) })
                })
        }
    }

    /// The most of a row's text sent, and rows a read gives by default and at most (`AgentReads`).
    static let textCap = 16 * 1024
    static let page = 20
    static let pageMax = 200

    static func row(_ e: LinkEntry, folder: URL) -> AgentRow {
        let text = LinkProjection.capped(e.text ?? "", textCap)
        let length = max(e.textLen, text.length)
        let tool = e.kind == .tool ? e.tool.map { t in
            AgentRow.Tool(
                name: t.name, summary: t.summary.map(title), path: t.path.map { LinkProjection.relative($0, to: folder) },
                input: t.input.map(title), result: t.result.map(LinkProjection.headAndTail))
        } : nil
        return AgentRow(
            id: e.id, kind: e.kind == .unknown ? "notice" : e.kind.rawValue, turn: e.turn, text: (e.text ?? "").isEmpty ? nil : text.text,
            textLen: text.cut || length > text.length ? length : nil, tool: tool, agent: e.agent?.name, done: e.done, error: e.isError ? true : nil,
            stopped: e.stopped ? true : nil)
    }

    static func rows(_ hc: HostChat, last: Int?, before: String?) -> AgentRows {
        hc.caughtUp()
        let entries = hc.entries
        let end = before.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.count
        let count = min(max(last ?? page, 1), pageMax)
        let start = max(0, end - count)
        let folder = URL(fileURLWithPath: hc.record.folder)
        return AgentRows(chat: hc.id, rows: entries[start..<end].map { row($0, folder: folder) }, more: start > 0)
    }

    /// The chat `ref` names among those the caller may read, or the refusal (`AgentChannel.resolve`'s words).
    private func resolve(_ ref: String?, _ hc: HostChat, in folder: String? = nil) -> Result<HostChat, Refused> {
        guard let ref, !ref.isEmpty else { return .failure(Refused(Self.failed(.noChat, "Name a chat: its title, its short id, or . for this one."))) }
        let shown = Dictionary(readable(hc, in: folder).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        switch AgentRefs.resolve(ref, chats: shown.values.map { (id: $0.id, title: $0.title) }, own: hc.id) {
        case .chat(let found):
            return shown[found].map(Result.success) ?? .failure(Refused(Self.failed(.noChat, "That chat isn't open in Kore.")))
        case .none:
            return .failure(Refused(Self.failed(.noChat, "No open chat matches \u{201C}\(ref)\u{201D}.")))
        case .notInChat:
            return .failure(Refused(Self.failed(.noChat, "This caller isn't in a Kore chat, so . names none.")))
        case .ambiguous(let ids):
            let names = ids.compactMap { shown[$0] }.map { "\(AgentRefs.short($0.id)) \($0.title)" }
            return .failure(Refused(Self.failed(.ambiguous, "Several chats match: " + names.joined(separator: ", "))))
        }
    }

    private func resolved(_ ref: String?, _ hc: HostChat, in folder: String? = nil, _ then: (HostChat) -> Data) -> Data {
        switch resolve(ref, hc, in: folder) {
        case .failure(let refused): refused.line
        case .success(let found): then(found)
        }
    }

    /// What a mode lets a chat do on its own, without starting its CLI to ask: the live chat's, else
    /// its record's mode.
    private func rank(_ hc: HostChat) -> (id: String, unreviewed: Bool, always: Bool) {
        if let chat = hc.chat {
            let rank = chat.arsenalRank
            return (rank.id, rank.unreviewed, chat.alwaysAllowed)
        }
        return (HostMeta.modeID(hc), false, false)
    }

    /// `chat` can do on its own no more than `other` (`Chat.noFreer(than:)`).
    private func noFreer(_ chat: HostChat, than other: HostChat) -> Bool {
        let (mine, theirs) = (rank(chat), rank(other))
        guard !mine.always || theirs.always else { return false }
        return Chat.noFreer(mine.id, unreviewed: mine.unreviewed, than: theirs.id, unreviewed: theirs.unreviewed)
    }

    /// Act unlimited reaches a chat at or below its own mode (`AgentChannel.drivable`).
    private func drivable(_ target: HostChat, _ hc: HostChat) -> Data? {
        guard tier(hc) >= .drive else { return Self.failed(.notOwn, "Act limited changes only this chat.") }
        guard noFreer(target, than: hc) else { return Self.failed(.notOwn, "That chat's mode is above this one's: only you drive it.") }
        return nil
    }

    /// A chat other than the caller's that it may drive.
    private func other(_ ref: String?, _ hc: HostChat, in folder: String? = nil, _ then: (HostChat) -> Data) -> Data {
        resolved(ref, hc, in: folder) { target in
            guard target !== hc else { return Self.failed(.refused, "Not this chat: it's the one asking.") }
            if let refused = drivable(target, hc) { return refused }
            if let held = Self.held(target) { return Self.failed(.refused, held.message) }
            return then(target)
        }
    }

    /// The caller's own chat (`.` when none is named), or with Act unlimited one it drives.
    private func changeable(_ ref: String?, _ hc: HostChat, _ then: (HostChat) -> Data) -> Data {
        resolved(ref ?? ".", hc) { target in
            if target !== hc, let refused = drivable(target, hc) { return refused }
            return then(target)
        }
    }

    /// The caller as the receiving chat names it (`AgentChannel.callerName`).
    private func callerName(_ hc: HostChat) -> String {
        let title = Self.title(hc.title).filter { !"“”\"\n\r".contains($0) }.prefix(60)
        return "“\(title)” · \(AgentRefs.short(hc.id))"
    }

    // MARK: Own

    private func change(_ hc: HostChat, _ name: String, _ args: AgentArgs) -> Data {
        changeable(args.chat, hc) { target in
            if name == AgentCommand.rename.name {
                guard let value = args.to, !value.isEmpty, value.utf8.count <= 1024 else { return Self.failed(.invalid, "Say what to set it to.") }
                switch Chat.arsenalName(value, taken: chats.filter { $0 !== target }.map(\.title)) {
                case .failure(let refusal): return Self.failed(.refused, refusal.message)
                case .success(let clean):
                    target.setTitle(clean)
                    target.chat?.rename(clean)
                    broadcast(chats: [target])
                    return Self.ok(AgentDone(chat: target.id, message: "Renamed."))
                }
            }
            if let held = Self.held(target) { return Self.failed(.refused, held.message) }
            guard let chat = live(target) else { return Self.failed(.refused, "Too many CLIs are running on this box.") }
            defer {
                target.noted(chat)
                armIdle(target)
                broadcast(chats: [target])
            }
            let caller = target === hc ? nil : hc.chat
            switch name {
            case AgentCommand.options.name:
                let o = chat.arsenalOptions(under: caller)
                return Self.ok(AgentOptions(
                    chat: target.id, models: o.models.map { .init(id: $0.id, name: $0.name, efforts: $0.efforts) }, model: o.model, effort: o.effort,
                    modes: o.modes.map { .init(id: $0.id, label: $0.label, allowed: $0.allowed) }, mode: o.mode, fast: o.fast))
            case AgentCommand.fast.name:
                guard let on = args.on else { return Self.failed(.invalid, "Say on or off.") }
                return Self.done(chat.arsenalFast(on), target)
            case AgentCommand.compact.name:
                return Self.done(chat.arsenalCompact(), target)
            default:
                guard let value = args.to, !value.isEmpty, value.utf8.count <= 1024 else { return Self.failed(.invalid, "Say what to set it to.") }
                let outcome = switch name {
                case AgentCommand.model.name: chat.arsenalModel(value)
                case AgentCommand.effort.name: chat.arsenalEffort(value)
                default: chat.arsenalMode(value, under: caller)
                }
                if case .success = outcome, name == AgentCommand.model.name, let id = chat.controls.modelId { target.setModel(id) }
                if case .success = outcome, name == AgentCommand.effort.name, let level = chat.controls.effort { target.setEffort(level) }
                return Self.done(outcome, target)
            }
        }
    }

    // MARK: Drive

    private func send(_ hc: HostChat, _ args: AgentArgs) -> Data {
        var folder: String?
        if let named = args.folder {
            // Another device's folder, with no Mac to reach it through.
            guard let path = historyFolder(named, of: hc) else { return Self.failed(.noWindow, Self.notConnected) }
            if Self.standard(path) != Self.standard(hc.record.folder), tier(hc) < .drive {
                return Self.failed(.noWindow, "Past chats can be read only for this chat's own folder: other folders need Act unlimited.")
            }
            folder = path
        }
        return other(args.chat, hc, in: folder) { target in
            guard let text = args.text, text.utf8.count <= ArsenalRules.textMax else {
                return Self.failed(.invalid, "Say the message, \(ArsenalRules.textMax / 1024) KiB at most.")
            }
            if let free = boxArsenal.sends[hc.id, default: RateLimiter(limit: ArsenalRules.sendsPerMinute, per: 60)].nextFree() {
                return Self.failed(.limit, "\(ArsenalRules.sendsPerMinute) messages a minute at most: " + ArsenalRules.freesUp(free))
            }
            guard let chat = live(target) else { return Self.failed(.refused, "Too many CLIs are running on this box.") }
            let outcome = chat.arsenalSend(text, from: callerName(hc))
            if case .success = outcome { _ = boxArsenal.sends[hc.id, default: RateLimiter(limit: ArsenalRules.sendsPerMinute, per: 60)].take() }
            armIdle(target)
            broadcast(chats: [target])
            return Self.done(outcome, target)
        }
    }

    /// Room for a chat it opens (`AgentChannel.roomForNew`).
    private func roomForNew(_ hc: HostChat) -> Data? {
        let open = Set(chats.map(\.id))
        let mine = (boxArsenal.made[hc.id] ?? []).filter(open.contains)
        boxArsenal.made[hc.id] = mine
        guard mine.count < ArsenalRules.madeOpen else { return Self.failed(.limit, "\(ArsenalRules.madeOpen) chats this one opened are open: close one first.") }
        if let free = boxArsenal.news[hc.id, default: RateLimiter(limit: ArsenalRules.newPerHour, per: 3600)].nextFree() {
            return Self.failed(.limit, "\(ArsenalRules.newPerHour) new chats an hour at most: " + ArsenalRules.freesUp(free))
        }
        return nil
    }

    /// A new chat in the caller's folder on this box, at or below its mode (`Workspace.arsenalNewChat`'s
    /// rules), its Arsenal off, and its first message if given.
    private func newChat(_ hc: HostChat, _ args: AgentArgs) -> Data {
        switch args.place {
        case nil, "box": break
        case "mac": return Self.failed(.noWindow, Self.notConnected)
        default: return Self.failed(.invalid, "place is box or mac.")
        }
        var folder = hc.record.folder
        if let named = args.folder {
            // The Mac's rule (`AgentChannel.folderTier`), in its words.
            let has = tier(hc)
            guard has >= .device else { return Self.failed(.tier, AgentTools.folderTierLine(has: has.rawValue)) }
            guard args.place == nil else { return Self.failed(.invalid, "Give folder or place, not both.") }
            // Not one this box serves: the Mac opens it, and it isn't here.
            guard let served = historyFolder(named, of: hc) else { return Self.failed(.noWindow, Self.notConnected) }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: served, isDirectory: &isDir), isDir.boolValue else {
                return Self.failed(.noWindow, "\(named) isn't a folder on this box.")
            }
            folder = served
        }
        if let refused = roomForNew(hc) { return refused }
        if let text = args.text, text.utf8.count > ArsenalRules.textMax {
            return Self.failed(.invalid, "A message can be \(ArsenalRules.textMax / 1024) KiB at most.")
        }
        guard let provider = Registry.provider(args.provider ?? hc.provider.id) else { return Self.failed(.refused, "Kore runs claude or codex.") }
        let rank = rank(hc)
        // At or below the caller's mode, and never above Auto (`LinkPolicy.raiseCap`).
        let cap = { (mode: String) in
            Chat.noFreer(mode, unreviewed: false, than: rank.id, unreviewed: rank.unreviewed) && LinkPolicy.cappedMode(mode, provider: provider.id) == mode
        }
        let modes = provider.modes.filter { $0.listed || $0.id == CodexModes.readOnly }
        let named = { (option: ModeOption, name: String) in option.id.lowercased() == name.lowercased() || option.label.lowercased() == name.lowercased() }
        var wanted: ModeOption?
        var plan = false
        if let mode = args.mode {
            if let toggle = provider.planToggle, named(toggle, mode) {
                plan = true
            } else {
                guard let found = modes.first(where: { named($0, mode) }) else {
                    return Self.failed(.refused, "\(provider.name)'s modes: " + (modes + [provider.planToggle].compactMap { $0 }).map(\.id).joined(separator: ", "))
                }
                guard cap(found.id) else { return Self.failed(.refused, "Only you can start a chat above your own mode.") }
                wanted = found
            }
        }
        let capped = modes.filter { cap($0.id) }
        guard !capped.isEmpty else {
            let label = hc.chat?.controls.activeMode.label ?? hc.provider.modes.first { $0.id == rank.id }?.label ?? rank.id
            return Self.failed(.refused, "Only you can open a \(provider.name) chat from this one: its lowest mode does more on its own than \(label).")
        }
        var launch: String?
        if let model = args.model {
            let known = clis.first { $0.provider == provider.id }?.models.map {
                ModelOption(id: $0.id, name: $0.name, resolved: $0.id, efforts: $0.efforts)
            } ?? []
            guard !known.isEmpty else { return Self.failed(.refused, "\(provider.name) here hasn't listed its models yet: open it without a model.") }
            switch ArsenalModels.find(model, in: known, cli: provider.name) {
            case .success(let option): launch = option.id
            case .failure(let refusal): return Self.failed(.refused, refusal.message)
            }
        }
        let usual = provider.modes.first?.id ?? ""
        if wanted == nil, !cap(usual) { wanted = capped.max { Chat.modeLevel($0.id) < Chat.modeLevel($1.id) } }
        guard let made = newChat(folder: folder, provider: provider.id, modelId: launch, mode: wanted?.id) else {
            return Self.failed(.refused, "Kore couldn't open a chat.")
        }
        _ = boxArsenal.news[hc.id, default: RateLimiter(limit: ArsenalRules.newPerHour, per: 3600)].take()
        boxArsenal.made[hc.id, default: []].append(made.id)
        // Made by this chat (and so by whatever made it): it never allows commands there.
        made.arsenalOrigins = [hc.id] + hc.arsenalOrigins.filter { $0 != hc.id }
        var message = "Opened a \(provider.name) chat" + (args.folder == nil ? "." : " in \(URL(fileURLWithPath: folder).lastPathComponent).")
        if plan || !(args.text ?? "").isEmpty {
            if let chat = live(made) {
                if plan { chat.setPlanMode(true) }
                if let text = args.text, !text.isEmpty {
                    switch chat.arsenalSend(text, from: callerName(hc)) {
                    case .success: message += " Sent."
                    case .failure(let refusal): message += " " + refusal.message
                    }
                }
                armIdle(made)
                broadcast(chats: [made])
            } else if !(args.text ?? "").isEmpty {
                message += " Too many CLIs are running on this box."
            }
        }
        return Self.ok(AgentDone(chat: made.id, message: message, short: AgentRefs.short(made.id)))
    }

    /// A chat closed as a client's tab close closes it, by its id only (`AgentChannel.closeChat`):
    /// kept, reopenable, never the caller's own, never one with anything in it that would be lost.
    private func close(_ hc: HostChat, _ args: AgentArgs) -> Data {
        guard let ref = args.chat, !ref.isEmpty, ref.utf8.count <= 128 else {
            return Self.failed(.noChat, "Name the chat by its short id (kore ls) or its full id.")
        }
        let shown = Dictionary(readable(hc).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let named = { (ids: [String]) in ids.compactMap { shown[$0] }.map { "\(AgentRefs.short($0.id)) “\(Self.title($0.title))”" }.joined(separator: ", ") }
        let target: HostChat
        switch AgentRefs.resolveID(ref, chats: shown.values.map { (id: $0.id, title: $0.title) }) {
        case .chat(let found):
            guard let found = shown[found] else { return Self.failed(.noChat, "That chat isn't open in Kore.") }
            target = found
        case .itself: return Self.failed(.refused, "A chat never closes itself.")
        case .none: return Self.failed(.noChat, "No open chat has the id \u{201C}\(ref)\u{201D}.")
        case .byTitle(let ids): return Self.failed(.ambiguous, "Close takes an id, never a title: " + named(ids))
        case .ambiguous(let ids): return Self.failed(.ambiguous, "Several chats have that short id: give the full one. " + named(ids))
        }
        guard target !== hc else { return Self.failed(.refused, "A chat never closes itself.") }
        if let refused = drivable(target, hc) { return refused }
        var hold = target.chat?.arsenalCloseHold ?? ArsenalCloseHold()
        hold.lastTab = !chats.contains { $0 !== target && $0.record.folder == target.record.folder }
        if let refusal = hold.refusal { return Self.failed(.refused, refusal) }
        let title = target.title
        close(target)
        return Self.ok(AgentDone(chat: target.id, message: "Closed “\(title)”. kore open \(AgentRefs.short(target.id)) brings it back.", short: AgentRefs.short(target.id)))
    }

    // MARK: History

    /// A folder a history read names, as a chat on this box names one: its own (`.`, a path, or the
    /// folder as the list shows it), or with Act unlimited another the box serves. Nil: not one of
    /// the box's.
    func historyFolder(_ folder: String, of hc: HostChat) -> String? {
        let own = hc.record.folder
        if folder == "." || folder == Self.shownFolder(own) { return own }
        var path = folder
        if let colon = folder.firstIndex(of: ":"), folder[..<colon] == Self.boxName { path = String(folder[folder.index(after: colon)...]) }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") { path = URL(fileURLWithPath: own).appendingPathComponent(path).path }
        let standard = Self.standard(path)
        return config.folders.first { Self.standard($0) == standard }
    }

    static let historyPage = 50

    private func historyList(_ hc: HostChat, _ args: AgentArgs) async -> Data {
        var folder = hc.record.folder
        if let named = args.folder {
            guard let found = historyFolder(named, of: hc) else { return Self.failed(.noWindow, "No Kore window has that folder open.") }
            if Self.standard(found) != Self.standard(folder) {
                guard tier(hc) >= .drive else {
                    return Self.failed(.noWindow, "Past chats can be read only for this chat's own folder: other folders need Act unlimited.")
                }
                folder = found
            }
        }
        let words = (args.query ?? "").lowercased().split(separator: " ")
        let all = await history(windowId: Self.windowID(folder), query: nil, archived: args.archived ?? false)
        let rows = all.filter { session in words.allSatisfy { session.title.lowercased().contains($0) } }
        let start = min(max(args.offset ?? 0, 0), rows.count)
        let page = rows[start..<min(start + Self.historyPage, rows.count)]
        let format = ISO8601DateFormatter()
        return Self.ok(AgentHistory(
            folder: Self.shownFolder(folder),
            sessions: page.map {
                AgentSession(
                    id: $0.id, provider: $0.provider, title: Self.title($0.title),
                    updated: format.string(from: Date(timeIntervalSince1970: Double($0.updatedAt) / 1000)), archived: $0.archived, open: $0.open)
            }, more: start + Self.historyPage < rows.count))
    }

    // MARK: Waiting

    private func wait(_ hc: HostChat, _ args: AgentArgs) async -> Data {
        switch resolve(args.chat, hc) {
        case .failure(let refused): return refused.line
        case .success(let target):
            guard target !== hc else { return Self.failed(.refused, "Not this chat: its turn is the one asking.") }
            guard Self.state(HostMeta.meta(target)) == "working" else { return waited(target, timedOut: false) }
            guard !boxArsenal.waits.contains(where: { $0.caller == hc.id && $0.target == target.id }) else {
                return Self.failed(.refused, "Already waiting on that chat.")
            }
            let seconds = min(max(args.timeout ?? ArsenalRules.waitMax, 1), ArsenalRules.waitMax)
            return await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
                let wait = HostArsenal.Wait(caller: hc.id, target: target.id) { done.resume(returning: $0) }
                boxArsenal.waits.append(wait)
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let at = self.boxArsenal.waits.firstIndex(where: { $0.token == wait.token }) else { return }
                        self.boxArsenal.waits.remove(at: at)
                        wait.done(self.chat(target.id).map { self.waited($0, timedOut: true) } ?? Self.failed(.noChat, "That chat closed."))
                    }
                }
            }
        }
    }

    private func waited(_ hc: HostChat, timedOut: Bool) -> Data {
        hc.caughtUp()
        let meta = HostMeta.meta(hc)
        let answer = hc.entries.last { $0.kind == .answer }.flatMap { Self.row($0, folder: URL(fileURLWithPath: hc.record.folder)).text }
        return Self.ok(AgentWaited(chat: hc.id, state: Self.state(meta), answer: answer, cards: meta.cards.count, timedOut: timedOut))
    }

    /// A chat moved on (an event, or it closed): each wait on it whose turn ended, or that closed, answers.
    func arsenalNoted(_ hc: HostChat) {
        guard boxArsenal.waits.contains(where: { $0.target == hc.id }) else { return }
        let open = chats.contains { $0 === hc }
        guard !open || Self.state(HostMeta.meta(hc)) != "working" else { return }
        let ended = boxArsenal.waits.filter { $0.target == hc.id }
        boxArsenal.waits.removeAll { $0.target == hc.id }
        for wait in ended { wait.done(open ? waited(hc, timedOut: false) : Self.failed(.noChat, "That chat closed.")) }
    }
}
