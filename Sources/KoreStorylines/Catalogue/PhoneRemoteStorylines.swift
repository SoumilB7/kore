import Foundation
import KorePhone
import KoreRemote
import KoreUI

// The phone remote (phase 13, part B), driven through a test phone on a loopback link: what the
// phone sees of Kore, what it may do, and the alerts it's sent.

/// The phone sees the window with its chat, follows the chat's transcript, and gets a message
/// sent on the Mac and its answer as they happen.
final class RemoteSnapshotLive: ChatStoryline {
    static let reply = "Hello from the script, **bold** and `code`."
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            AttachPhone(),
            Expect.phone("the window with the chat in a tab") { phone, id in
                phone.windows.contains { $0.tabs.contains { $0.kind == .chat && $0.chatId == id } } && phone.chats[id] != nil
            },
            PhoneOpensChat(),
            Send("Say hello"),
            TurnFinished(1),
            Expect.phone("the message, then the whole answer as formatted text") { phone, id in
                let lines = phone.lines(id)
                return lines.contains { $0.kind == .user && $0.text == "Say hello" }
                    && lines.last.map { $0.kind == .answer && $0.text == "Hello from the script, bold and code." } == true
            },
            Expect.phone("the chat idle again") { phone, id in phone.chats[id]?.running == false && phone.chats[id]?.state == .idle },
        ]
    }
}

/// The phone sends a message, then another while the turn runs: the second waits queued and the
/// CLI takes it into the turn, as one typed on the Mac would.
final class RemoteSendQueued: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .stream(.answer, "Working on it.\n\n"), .takeQueued, .stream(.answer, "Done."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            AttachPhone(),
            PhoneOpensChat(),
            PhoneCommand(what: "send “Start”") { .send(chatId: $0, text: "Start") },
            Expect("the turn running") { try $0.activeChat().isRunning },
            PhoneCommand(what: "send “And the tests” while it runs") { .send(chatId: $0, text: "And the tests") },
            TurnFinished(1),
            Expect("the CLI sent the first, then took the second into the turn") { story in
                let log = try story.scriptedBackend().log
                return log.contains(.send("Start")) && log.contains(.queued("And the tests"))
            },
            Expect.phone("both messages in the transcript") { phone, id in
                let users = phone.lines(id).filter { $0.kind == .user }.map(\.text)
                return users == ["Start", "And the tests"]
            },
        ]
    }
}

/// A permission card shows on the phone and as an alert; Always allow is refused from the phone,
/// Allow goes through, and the card and its alert clear.
final class RemoteAnswerApproval: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals, .gate] }
    override class var script: CLIScript {
        let approval = Approval(id: "first", title: "Run rm -rf build?", detail: "Bash", body: "rm -rf build", canAlwaysAllow: true, questions: [])
        return CLIScript(turns: [[
            .startTurn,
            .approval(approval, allow: [.tool(name: "Bash", detail: "rm -rf build", output: "removed")], deny: Beat.answer("Okay.")),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            AttachPhone(),
            PhoneCommand(what: "send “Clean the build”") { .send(chatId: $0, text: "Clean the build") },
            Expect.phone("the card, with Always allow marked refused") { phone, id in
                guard let card = phone.chats[id]?.cards.first(where: { $0.id == "first" }) else { return false }
                return card.kind == .permission && card.body == "rm -rf build"
                    && card.actions.contains { $0.id == .allowAlways && $0.refused == true } && phone.chats[id]?.state == .needsYou
            },
            Expect.phone("an alert open for it") { phone, id in phone.open["\(id)/first"]?.kind == .approval },
            PhoneCommand(what: "always allow", command: { .answer(chatId: $0, cardId: "first", action: .allowAlways, answers: nil) }, refused: .alwaysAllow),
            Expect("the card still waiting on the Mac") { try !$0.activeChat().pendingApprovals.isEmpty },
            PhoneCommand(what: "allow") { .answer(chatId: $0, cardId: "first", action: .allow, answers: nil) },
            Expect("the CLI was told yes") { try $0.scriptedBackend().log.contains(.respond(approval: "first", allowed: true)) },
            TurnFinished(1),
            Expect.phone("no card and no alert left") { phone, id in phone.chats[id]?.cards.isEmpty == true && phone.open.isEmpty },
            Expect.phone("the turn's end as an alert") { phone, id in phone.turnEnds.contains { $0.chatId == id && $0.outcome == .finished } },
        ]
    }
}

/// The phone may only lower a chat's mode, and sends only where tools still ask.
final class RemoteRaiseDenied: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let claude = variant == .claude
        let higher = claude ? "acceptEdits" : "approveForMe"
        let top = claude ? "acceptEdits" : "fullAccess"
        let lower: [any Step] =
            claude
            ? [
                PhoneCommand(what: "switch to Plan") { .setMode(chatId: $0, modeId: "plan") },
                Expect("the Mac's chat in Plan") { try $0.activeChat().mode == "plan" },
            ]
            : [
                PhoneCommand(what: "turn plan on") { .setPlan(chatId: $0, on: true) },
                Expect("the Mac's chat planning") { try $0.activeChat().storyPlanMode },
            ]
        return super.steps() + [
            AttachPhone(),
            PhoneCommand(what: "switch to \(higher)", command: { .setMode(chatId: $0, modeId: higher) }, refused: .raiseMode),
            Expect("the Mac's chat still in its mode") { try $0.activeChat().mode != higher },
        ] + lower + [
            Do("switch the chat to \(top) on the Mac") { try $0.activeChat().setMode(top, remember: false) },
        ] + (claude ? [] : [Do("turn plan off on the Mac") { try $0.activeChat().setPlanMode(false) }]) + [
            Expect.phone("the chat shown as not sendable") { phone, id in phone.chats[id]?.mode.id == top && phone.chats[id]?.can.send == false },
            PhoneCommand(what: "send to it", command: { .send(chatId: $0, text: "Deploy it") }, refused: .sendCap),
            PhoneCommand(what: "send /login", command: { .send(chatId: $0, text: "/login") }, refused: .sendCap),
        ]
    }
}

/// A message from the phone leaves what's being typed on the Mac as it was.
final class RemoteMacDraftUntouched: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("type a half-written note on the Mac") { try $0.activeChat().draft = "half-written note" },
            AttachPhone(),
            PhoneCommand(what: "send “From the phone”") { .send(chatId: $0, text: "From the phone") },
            TurnFinished(1),
            Expect("the Mac's draft as it was") { try $0.activeChat().draft == "half-written note" },
            Expect("the phone's message sent") { try $0.scriptedBackend().log.contains(.send("From the phone")) },
        ]
    }
}

/// A phone in the background gets alerts only: a card opens one, answering it on the Mac clears
/// it, and the turn's end comes as one. It's sent no windows or transcripts.
final class RemoteAttentionApproval: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals, .gate] }
    override class var script: CLIScript { RemoteAnswerApproval.script }

    override func steps() -> [any Step] {
        super.steps() + [
            AttachPhone(mode: .background),
            Send("Clean the build"),
            Expect.phone("an alert for the card") { phone, id in phone.open["\(id)/first"]?.kind == .approval },
            Answer(.allow),
            Expect.phone("the alert cleared by the Mac's answer") { phone, _ in phone.open.isEmpty },
            TurnFinished(1),
            Expect.phone("the turn's end as an alert") { phone, id in phone.turnEnds.contains { $0.chatId == id && $0.outcome == .finished } },
            Expect.phone("no windows or transcripts sent") { phone, _ in
                phone.rev == 0 && !phone.received.contains("snapshot") && !phone.received.contains("tx.page")
            },
        ]
    }
}

/// A phone that was away hears, when it comes back, of the turns that ended meanwhile.
final class RemoteAwayThenBack: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            AttachPhone(mode: .background),
            DisconnectPhone(),
            Send("Say hello"),
            TurnFinished(1),
            AttachPhone(mode: .background, resumeAttention: true),
            Expect.phone("the turn that ended while it was away") { phone, id in
                phone.turnEnds.contains { $0.chatId == id && $0.outcome == .finished }
            },
        ]
    }
}
