import Foundation
import LinkProtocol
import src

/// A box chat's state as the link sends it: its meta, its cards, the facts the policy checks.
/// Plans go as text (`body`), never as a render tree: the client renders.
@MainActor
enum HostMeta {
    static let bodyCap = 4 * 1024
    static let planReadyID = "planReady"

    static func level(_ mode: ModeOption) -> ModeLevel { ModeLevel(rawValue: mode.level) ?? .danger }

    static func providers() -> [ProviderInfo] {
        Registry.all.map { p in
            ProviderInfo(
                id: p.id, name: p.name,
                modes: p.modes.map { ModeInfo(id: $0.id, label: $0.label, level: level($0), listed: $0.listed) },
                planToggle: p.planToggle.map { PlanToggleInfo(id: $0.id, label: $0.label) },
                features: ProviderFeatures(effort: true, fastMode: p.id == "claude"))
        }
    }

    static func modeID(_ hc: HostChat) -> String { hc.chat?.controls.mode ?? hc.record.mode ?? hc.provider.modes[0].id }

    static func facts(_ hc: HostChat) -> LinkPolicy.ChatFacts {
        let provider = hc.provider
        let modes = Dictionary(provider.modes.map { ($0.id, level($0)) }, uniquingKeysWith: { a, _ in a })
        let current = modes[modeID(hc)] ?? .manual
        let cards = Dictionary(self.cards(hc).map { ($0.id, LinkPolicy.ChatFacts.Card(kind: $0.kind, digest: $0.digest)) }, uniquingKeysWith: { a, _ in a })
        let commands = hc.chat?.controls.commands ?? []
        return LinkPolicy.ChatFacts(
            level: current, planOn: provider.planToggle != nil && (hc.chat?.controls.planMode ?? false), modes: modes, cards: cards,
            commands: Set(commands.filter { $0.kind != .kore }.map(\.name)), koreEntries: Set(commands.filter { $0.kind == .kore }.map(\.name)))
    }

    /// `raise`: the grant may raise the mode (a full grant), so every mode is allowed.
    static func meta(_ hc: HostChat, raise: Bool = false) -> ChatMeta {
        let facts = facts(hc)
        let allowed = LinkPolicy.allowedModes(facts, control: raise ? .full : .standard)
        let chat = hc.chat
        let state: ChatMeta.State =
            if let chat, !chat.approvals.pending.isEmpty || chat.approvals.offerImplementPlan { .needsYou }
            else if chat?.isWorking == true { .working }
            else { .idle }
        let commands = (chat?.controls.commands ?? [])
            .filter { $0.kind != .kore && !LinkPolicy.koreOnly.contains($0.name) }
            .prefix(200)
            .map { LinkSlash(name: $0.name, description: String($0.description.prefix(100)), kind: $0.kind == .skill ? .skill : .command) }
        return ChatMeta(
            id: hc.id, provider: hc.provider.id, title: hc.title, state: state,
            mode: .init(id: modeID(hc), level: facts.level, planOn: hc.provider.planToggle != nil ? (chat?.controls.planMode ?? false) : nil),
            modeIds: (chat?.controls.availableModes ?? hc.provider.modes).map(\.id), allowedModeIds: allowed.sorted(),
            model: chat?.controls.currentModel?.name ?? hc.record.modelId, queued: chat?.queuedCount ?? 0, running: chat?.isBusy ?? false,
            cards: cards(hc), can: .init(send: !(chat?.accountRestartPending ?? false), stop: chat?.isWorking ?? false), commands: Array(commands))
    }

    static func kind(_ approval: Approval) -> LinkCard.Kind {
        if approval.signIn { return .signIn }
        if approval.plan != nil { return .plan }
        if !approval.questions.isEmpty { return .questions }
        return .permission
    }

    static func cards(_ hc: HostChat) -> [LinkCard] {
        guard let chat = hc.chat else { return [] }
        var out = chat.approvals.pending.map { card($0, in: chat) }
        if chat.approvals.offerImplementPlan {
            let actions: [CardAction] = [
                .init(id: .implement, label: "Yes, implement it", style: .primary), .init(id: .stay, label: "Stay in Plan", style: .neutral),
            ]
            let title = "Implement this plan?"
            let digest = LinkCardDigest(kind: .planReady, title: title, detail: nil, body: nil, plan: nil, questions: nil, actions: actions).digest
            out.append(LinkCard(id: planReadyID, kind: .planReady, title: title, actions: actions, digest: digest))
        }
        return out
    }

    /// A card's whole content: a plan's text, else its body. What `card.more` reads.
    static func fullContent(_ approval: Approval) -> String? { approval.plan ?? approval.body }

    static func card(_ approval: Approval, in chat: Chat) -> LinkCard {
        let agent: String? =
            switch approval.agent {
            case .main: nil
            case .sub(let id): chat.transcriptView.agent(id)?.name ?? id
            }
        let kind = kind(approval)
        let body = fullContent(approval).map { LinkProjection.capped($0, bodyCap) }
        let actions: [CardAction]
        var questions: [LinkQuestion]?
        switch kind {
        case .signIn, .unknown:
            actions = []
        case .plan:
            actions = [
                .init(id: .approvePlan, label: "Yes, manually approve edits", style: .primary),
                .init(id: .approvePlanAcceptEdits, label: "Yes, and auto-accept edits", style: .neutral, refused: true),
                .init(id: .keepPlanning, label: "No, keep planning", style: .neutral),
            ]
        case .questions:
            questions = approval.questions.map { q in
                LinkQuestion(
                    id: q.id, text: q.text, header: q.header,
                    options: q.options.map { .init(label: $0.label, description: $0.description, preview: $0.preview) }, multiple: q.multiple,
                    secret: q.secret, other: q.other)
            }
            actions = [.init(id: .submitAnswers, label: "Submit", style: .primary), .init(id: .deny, label: "Skip", style: .neutral)]
        case .permission, .planReady:
            actions =
                [.init(id: .allow, label: "Allow", style: .primary)]
                + (approval.canAlwaysAllow ? [.init(id: .allowAlways, label: "Always allow", style: .neutral, refused: true)] : [])
                + [.init(id: .deny, label: "Deny", style: .destructive)]
        }
        let digest = LinkCardDigest(
            kind: kind, title: approval.title, detail: approval.detail, body: approval.body, plan: approval.plan, questions: questions,
            actions: actions
        ).digest
        return LinkCard(
            id: approval.id, kind: kind, title: approval.title, detail: approval.detail, body: body?.text,
            bodyLen: body?.cut == true ? body?.length : nil, plan: nil, questions: questions, agent: agent, actions: actions, digest: digest)
    }
}
