import AppKit
import Foundation
import KoreCore
import KoreUI
import src

// Every chat control driven once, its effect checked (`--tag drive`): approval and question
// cards, the Account popup, and the composer's chips, pickers and cards.

// MARK: - Approval cards

/// A box chat's card offers Always allow dim, set on the box itself: pressing it answers
/// nothing and the card waits; Allow then answers it.
final class DriveApprovalBoxNote: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let card = Approval(id: "box1", title: "Run make", detail: "Build the app", body: "make", canAlwaysAllow: true, questions: [])
        .withoutAlwaysAllow(note: "Always allow is set on mybox itself.")
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .approval(card, allow: Beat.answer("Built."), deny: []), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let id = StoryID.Approval.card("box1")
        return super.steps() + [
            Send("Build it"),
            WaitForElement(.id(id.part(.always))),
            Press(.id(id.part(.always))),
            WaitIdle(),
            Expect("the card still waits, nothing answered") { story in
                let log = try story.scriptedBackend().log
                return try story.activeChat().pendingApprovals.contains { $0.id == "box1" }
                    && !log.contains(.respond(approval: "box1", allowed: true)) && !log.contains(.respond(approval: "box1", allowed: false))
            },
            Press(.id(id.part(.allow))),
            DriveChat.asked("Allow answered it", .respond(approval: "box1", allowed: true)),
            TurnFinished(1),
        ]
    }
}

/// "Ready to code?": each of its three buttons answers the plan, the card goes, and the turn
/// goes on as the answer says (keep planning is a no; both approvals a yes, Accept edits being
/// the CLI's own switch once it's told).
class DrivePlanCard: ChatStoryline {
    override class var isFamily: Bool { self == DrivePlanCard.self }
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    class var button: StoryID.Part { .approveplan }
    class var approves: Bool { true }
    static let plan = Approval(
        id: "plan1", title: "Ready to code?", detail: nil, body: nil, canAlwaysAllow: false, questions: [],
        plan: "1. Move the views onto tokens.\n2. Apply the snaps.")
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .approval(plan, allow: Beat.answer("Coding now."), deny: Beat.answer("Planning on.")), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let id = StoryID.Approval.card("plan1")
        let approves = Self.approves
        return super.steps() + [
            Send("Plan the change"),
            WaitForElement(.id(id.part(Self.button))),
            Press(.id(id.part(Self.button))),
            DriveChat.asked("the plan answered", .respond(approval: "plan1", allowed: approves)),
            ExpectElement(.id(id.part(.approveplan)), .absent),
            TurnFinished(1),
            Expect.rows("the turn went on as answered") { rows in rows.last { $0.kind == "assistant" }?.text == (approves ? "Coding now." : "Planning on.") },
        ]
    }
}

final class DrivePlanKeepPlanning: DrivePlanCard {
    override class var button: StoryID.Part { .keepplanning }
    override class var approves: Bool { false }
}

final class DrivePlanApprove: DrivePlanCard {
    override class var button: StoryID.Part { .approveplan }
}

final class DrivePlanAutoAccept: DrivePlanCard {
    override class var button: StoryID.Part { .autoaccept }
}

/// Codex's "Implement this plan?" after a plan in Plan mode.
class DriveImplementPlan: ChatStoryline {
    override class var isFamily: Bool { self == DriveImplementPlan.self }
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        CLIScript(turns: [
            [.startTurn, .stream(.answer, "1. Move the views onto tokens.\n2. Apply the snaps."), .event(.planReady), .finishTurn(.completed)],
            CLIScript.reply("Implemented."),
        ])
    }

    var opening: [any Step] {
        super.steps() + [
            Do("Plan mode on") { try $0.activeChat().setPlanMode(true) },
            Expect("Plan mode on") { try $0.activeChat().storyPlanMode },
            Send("Plan the change"), TurnFinished(1), WaitIdle(),
            WaitForElement(.id(StoryID.Approval.implementPlan.part(.allow))),
        ]
    }
}

/// Stay in Plan: the offer goes, Plan stays on, nothing is sent.
final class DriveImplementPlanStay: DriveImplementPlan {
    override func steps() -> [any Step] {
        opening + [
            Press(.id(StoryID.Approval.implementPlan.part(.keepplanning))),
            ExpectElement(.id(StoryID.Approval.implementPlan.part(.allow)), .absent),
            Expect("Plan still on, nothing sent") { story in
                let log = try story.scriptedBackend().log
                return try story.activeChat().storyPlanMode && !log.contains(.send("Implement the plan."))
            },
        ]
    }
}

/// Implement: Plan turns off and the chat asks for the plan to be carried out.
final class DriveImplementPlanImplement: DriveImplementPlan {
    override func steps() -> [any Step] {
        opening + [
            Press(.id(StoryID.Approval.implementPlan.part(.allow))),
            DriveChat.asked("Plan turned off", .setPlanMode(false)),
            DriveChat.asked("the plan asked for", .send("Implement the plan.")),
            TurnFinished(2),
            ExpectElement(.id(StoryID.Approval.implementPlan.part(.allow)), .absent),
            Expect("Plan off") { try !$0.activeChat().storyPlanMode },
        ]
    }
}

// MARK: - Question cards

@MainActor private func driveQuestionScript(_ question: Approval.Question) -> CLIScript {
    let approval = Approval(id: "q1", title: "", detail: nil, body: nil, canAlwaysAllow: false, questions: [question])
    return CLIScript(turns: [[.startTurn, .approval(approval, allow: Beat.answer("Got it."), deny: []), .finishTurn(.completed)]])
}

@MainActor private func driveShown(_ id: StoryID) -> Bool { StoryRegistry.ids.contains(id.raw) }

/// Other open, picked again: it closes, its field goes; an option then answers.
final class DriveQuestionOtherRepick: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let question = "Which settings layout?"
    override class var script: CLIScript {
        driveQuestionScript(Approval.Question(
            id: question, text: question, header: "Layout",
            options: [.init(label: "Tabs", description: "One pane per area"), .init(label: "Sidebar", description: "Sections left, detail right")]))
    }

    override func steps() -> [any Step] {
        let other = StoryID.Approval.other(Self.question)
        return super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(other)),
            Press(.id(other)),
            WaitForElement(.id(other.part(.field))),
            Expect("Other picked") { _ in driveShown(other.part(.ticks)) },
            Press(.id(other)),
            ExpectElement(.id(other.part(.field)), .absent),
            Expect("Other picked again: closed") { _ in !driveShown(other.part(.ticks)) },
            Press(.id(StoryID.Approval.option(Self.question, "Tabs"))),
            Press(.id(StoryID.Approval.card("q1").part(.submit))),
            TurnFinished(1),
            Expect("only the option sent", found: { story in (try? story.scriptedBackend().answers["q1"]).map { "\($0)" } }) { story in
                try story.scriptedBackend().answers["q1"] == [Self.question: ["Tabs"]]
            },
        ]
    }
}

/// A secret question: its answer is typed hidden, and goes back as typed.
final class DriveQuestionSecret: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript {
        driveQuestionScript(Approval.Question(id: "token", text: "Paste the deploy token", header: "Token", options: [], secret: true))
    }

    override func steps() -> [any Step] {
        let field = StoryID.Approval.other("token").part(.field)
        return super.steps() + [
            Send("Deploy"),
            WaitForElement(.id(field)),
            Click(.id(field)),
            Expect("the hidden field has the keys") { story in story.window?.firstResponder is NSText },
            TypeText("hunter2"),
            Expect("Submit ready") { _ in driveShown(StoryID.Approval.card("q1").part(.done)) },
            Press(.id(StoryID.Approval.card("q1").part(.submit))),
            TurnFinished(1),
            Expect("the typed answer sent", found: { story in (try? story.scriptedBackend().answers["q1"]).map { "\($0)" } }) { story in
                try story.scriptedBackend().answers["q1"] == ["token": ["hunter2"]]
            },
        ]
    }
}

// MARK: - Account popup

@MainActor private enum DriveAccount {
    static let popup = Locator.id(StoryID.Composer.account)
    static func part(_ part: StoryID.Part) -> Locator { .id(StoryID.Composer.account.part(part)) }

    static func opening(_ provider: String) -> [any Step] {
        [
            UseScript(AccountPopup.script(provider), for: provider), OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
        ]
    }

    static func lines(_ what: String, _ check: @escaping @MainActor ([String]) -> Bool) -> Expect {
        Expect(what, found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) { check($0.app.chat?.storyAccount ?? []) }
    }
}

/// Codex's device code: Copy code puts the code on the pasteboard.
final class DriveAccountCopyCode: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        DriveAccount.opening("codex") + [
            Do("the next sign-in shows a device code") { _ in ScriptedAccounts.shared.start["codex"] = .deviceCode("K7QM-4XWD") },
        ] + AccountMethods.pick("Sign in with Device Code") + [
            DriveAccount.lines("the code to enter") { $0.contains("Enter K7QM-4XWD") },
            Do("clear the pasteboard") { _ in _ = NSPasteboard(name: StoryHost.board).clearContents() },
            Press(DriveAccount.part(.copy)),
            Expect("the code copied", found: { _ in NSPasteboard(name: StoryHost.board).string(forType: .string) }) { _ in
                NSPasteboard(name: StoryHost.board).string(forType: .string) == "K7QM-4XWD"
            },
            Press(DriveAccount.part(.cancel)),
            DriveAccount.lines("cancelled") { !$0.contains("Enter K7QM-4XWD") },
        ]
    }
}

/// Codex's own key: Cancel clears the field and closes it, sending nothing; the popup stays.
final class DriveAccountKeyCancel: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        DriveAccount.opening("codex") + AccountMethods.pick("Provide your own API key…") + [
            WaitForFocus(.id(StoryID.Composer.accountField("key"))),
            TypeText("sk-kore-drive-0001"),
            Expect("“sk-kore-drive-0001” in the field", found: { story in (story.window?.firstResponder as? NSTextView)?.string }) { story in
                (story.window?.firstResponder as? NSTextView)?.string.hasSuffix("sk-kore-drive-0001") == true
            },
            Expect("the key field open") { $0.app.chat?.storyAccountEditing == true },
            Press(DriveAccount.part(.cancel)),
            ExpectElement(.id(StoryID.Composer.accountField("key")), .absent),
            Expect("closed, the popup still open, no key sent") { story in
                story.app.chat?.storyAccountEditing == false && story.app.chat?.isAccountOpen == true
                    && !ScriptedAccounts.shared.log.contains(.key("codex"))
            },
        ]
    }
}

/// Claude's Amazon Bedrock form: Cancel closes it, writing nothing to Claude's settings.
final class DriveAccountFormCancel: Storyline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    @MainActor static func settingsText() -> String { (try? String(contentsOf: ClaudeSettings.userFile(), encoding: .utf8)) ?? "" }

    override func steps() -> [any Step] {
        let before = DriveChatNote("")
        return DriveAccount.opening("claude") + [
            Do("note Claude's settings") { _ in before.value = Self.settingsText() },
        ] + AccountMethods.pick("3rd-party platform/Amazon Bedrock…") + [
            DriveAccount.lines("the Bedrock form") { $0.first == "Amazon Bedrock" },
            Expect("the form open") { $0.app.chat?.storyAccountEditing == true },
            Press(DriveAccount.part(.cancel)),
            Expect("closed, the popup still open") { story in
                story.app.chat?.storyAccountEditing == false && story.app.chat?.isAccountOpen == true
                    && story.app.chat?.storyAccount.first != "Amazon Bedrock"
            },
            Expect("Claude's settings as they were") { _ in Self.settingsText() == before.value },
        ]
    }
}

/// Moving the only Codex login here to a box asks once in its row, then No or Move answers.
class DriveAccountMoveOnly: Storyline {
    override class var isFamily: Bool { self == DriveAccountMoveOnly.self }
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let credential = Data(#"{"tokens":{"access_token":"a","refresh_token":"drive-r1","account_id":"acct"},"last_refresh":"2026-11-18T10:00:00Z"}"#.utf8)
    static let main = StoryID.Composer.accountLogin("main")

    /// mybox, held in memory: it keeps one Codex login.
    static func box() -> AccountMove.StoryBox {
        let box = AccountMove.StoryBox()
        box.cli = "codex"
        box.login = "main"
        return box
    }

    /// The boxes a move offers, as they were before the storyline.
    typealias Boxes = DriveChatNote<(@MainActor () -> [LoginMoves.Box])?>

    static func opening(_ box: AccountMove.StoryBox, _ boxes: Boxes) -> [any Step] {
        [
            UseScript(AccountPopup.script("codex"), for: "codex"), SeedLogins(provider: "codex"),
            Do("the main login's credential here, and mybox to move it to") { _ in
                let vault = ScriptedAccounts.shared.loginVault
                vault.set(Self.credential, LoginVault.Place(cli: "codex", folder: nil))
                if let folder = CLIProfiles.mains.value["codex"] { vault.set(Self.credential, LoginVault.Place(cli: "codex", folder: folder)) }
                boxes.value = LoginMoves.shared.boxes
                LoginMoves.shared.boxes = {
                    [LoginMoves.Box(
                        key: "mybox", name: "mybox", unready: nil, device: nil, remote: { _, _, _, _ in box }, prints: { _, _ in [] },
                        login: { _, _ in box.login })]
                }
            },
            OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(DriveAccount.popup),
            // One login is a list of one: its row's ⋯ shows under the pointer.
            DriveChatSettle(), Press(.id(main.part(.hover))), Press(.id(main.part(.method))),
            WaitForElement(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            Press(.id(StoryID.Composer.accountMethod("Move to mybox"))),
            WaitForElement(.id(main.part(.deny))),
            ExpectElement(.id(main.part(.allow))),
        ]
    }

    static func closing(_ boxes: Boxes) -> [any Step] {
        [Do("mybox gone again") { _ in if let kept = boxes.value { LoginMoves.shared.boxes = kept } }]
    }
}

/// No: the question goes and the login stays here, nothing sent to the box.
final class DriveAccountMoveOnlyNo: DriveAccountMoveOnly {
    override func steps() -> [any Step] {
        let (box, boxes) = (Self.box(), Boxes(nil))
        return Self.opening(box, boxes) + [
            Press(.id(Self.main.part(.deny))),
            ExpectElement(.id(Self.main.part(.deny)), .absent),
            Expect("not moved: nothing on mybox, no move under way") { _ in
                LoginMoves.shared.line("codex", nil) == nil && box.staged.isEmpty && box.placed.isEmpty
            },
        ] + Self.closing(boxes)
    }
}

/// Move: the question goes and the move begins.
final class DriveAccountMoveOnlyMove: DriveAccountMoveOnly {
    override func steps() -> [any Step] {
        let (box, boxes) = (Self.box(), Boxes(nil))
        return Self.opening(box, boxes) + [
            Press(.id(Self.main.part(.allow))),
            ExpectElement(.id(Self.main.part(.allow)), .absent),
            Expect("the move under way, done or saying why", found: { _ in "\(String(describing: LoginMoves.shared.line("codex", nil))), on mybox: \(box.placed.keys.sorted())" }) { _ in
                LoginMoves.shared.line("codex", nil) != nil || box.placed["main"] == Self.credential
            },
        ] + Self.closing(boxes)
    }
}

// MARK: - Composer

/// Codex's Plan mark beside the mode: a click turns Plan off.
final class DrivePlanChipOff: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Plan mode on") { try $0.activeChat().setPlanMode(true) },
            WaitForElement(.id(StoryID.Composer.planChip)),
            Press(.id(StoryID.Composer.planChip)),
            Expect("Plan off") { try !$0.activeChat().storyPlanMode },
            DriveChat.asked("the CLI told", .setPlanMode(false)),
            ExpectElement(.id(StoryID.Composer.planChip), .absent),
        ]
    }
}

/// An attached file's ×: the chip goes and nothing is attached.
final class DriveAttachmentRemove: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        let chip = StoryID.Composer.attachment("notes.txt")
        return super.steps() + [
            Do("attach a file of the folder") { story in
                let file = story.folder.appendingPathComponent("notes.txt")
                try "Some notes.\n".write(to: file, atomically: true, encoding: .utf8)
                try story.activeChat().storyAttach([file])
            },
            WaitForElement(.id(chip.part(.close))),
            Press(.id(chip.part(.close))),
            Expect("nothing attached") { try $0.activeChat().attachments.isEmpty },
            ExpectElement(.id(chip), .absent),
        ]
    }
}

/// A click on the padding under the composer's text gives it the keys, the caret at the end.
final class DriveComposerPaddingFocus: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            SetDraft("hello"),
            Do("the keys away from the composer") { _ = $0.window?.makeFirstResponder(nil) },
            Expect("the composer without the keys") { !($0.window?.firstResponder is NSTextView) },
            DriveChatClickAt(target: .id(StoryID.Composer.fieldBox), place: "on its padding, under the text") { frame in
                CGVector(dx: 0, dy: -(frame.height / 2) + 3)
            },
            WaitForFocus(.id(StoryID.Composer.field)),
            Expect("the caret at the end", found: { story in (story.window?.firstResponder as? NSTextView).map { "\($0.selectedRange())" } }) { story in
                (story.window?.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 5, length: 0)
            },
            TypeText("!"),
            Expect("typed at the end") { try $0.activeChat().draft == "hello!" },
        ]
    }
}

/// The model picker's effort slider: a drag slides the level, up and down.
final class DriveEffortDrag: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    /// From the slider's middle (medium, of low, medium and high) by a column.
    static func column(_ sign: CGFloat) -> @MainActor (StoryContext) throws -> CGVector {
        { _ in
            guard let frame = StoryElement(StoryID.Composer.effort)?.frame else { throw StoryFailure.modelMissing("the effort slider") }
            return CGVector(dx: sign * frame.width / 3, dy: 0)
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            Expect("medium to start") { $0.app.chat?.storyEffort == "medium" },
            Press(.id(StoryID.Composer.model)),
            WaitForElement(.id(StoryID.Composer.models)),
            WaitForElement(.id(StoryID.Composer.effort)),
            Drag(.id(StoryID.Composer.effort), by: Self.column(1)),
            Expect("dragged right: high", found: { $0.app.chat?.storyEffort }) { $0.app.chat?.storyEffort == "high" },
            DriveChat.asked("the CLI told", .setEffort("high")),
            Drag(.id(StoryID.Composer.effort), by: Self.column(-1)),
            Expect("dragged left: low", found: { $0.app.chat?.storyEffort }) { $0.app.chat?.storyEffort == "low" },
            DriveChat.asked("the CLI told", .setEffort("low")),
        ]
    }
}

/// The command chip before the text: a click opens the / menu again, to change it.
final class DriveCommandChipReopens: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { SlashMenuCaret.script }

    override func steps() -> [any Step] {
        let review = Locator.id(StoryID.Composer.command("review"))
        return super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            Press(review),
            Expect("/review in the chip") { $0.app.chat?.command?.name == "review" },
            ExpectElement(review, .absent),
            Press(.id(StoryID.Composer.chip)),
            WaitForElement(.id(StoryID.Composer.command("compact"))),
            ExpectElement(review),
        ]
    }
}

/// The Usage popup's extended card: a click beside the card closes it.
final class DriveUsageModalOutside: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript { UsagePopup.claude }

    override func steps() -> [any Step] {
        let card = Locator.id(StoryID.UsageModal.card)
        return [UseScript(UsagePopup.claude, for: "claude"), OpenFolder(), StartChat()] + [
            WaitForFocus(.id(StoryID.Composer.field)),
            Expect("the chat has its session") { $0.app.chat?.sessionId != nil },
            Press(.id(StoryID.Composer.slash)),
            Press(.id(StoryID.Composer.command("usage"))),
            WaitForElement(.id(StoryID.Composer.usage)),
            WaitForElement(.id(StoryID.Composer.usage.part(.extended)), timeout: .seconds(10)),
            Click(.id(StoryID.Composer.usage.part(.extended))),
            WaitForElement(card),
            Expect("the card open") { $0.app.chat?.isUsageExtendedOpen == true },
            DriveChatClickAt(target: .id(StoryID.UsageModal.backdrop), place: "beside the card, at the left") { frame in
                CGVector(dx: -(frame.width / 2) + 8, dy: 0)
            },
            ExpectElement(card, .absent),
            Expect("the card closed") { $0.app.chat?.isUsageExtendedOpen == false },
        ]
    }
}

/// The context card's track, as a person's mouse and keys move its notch.
class DriveContextTrack: ChatStoryline {
    override class var isFamily: Bool { self == DriveContextTrack.self }
    override class var tags: Set<Tag> { [.drive] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .stream(.answer, "Read the folder."), .context(used: 50_000), .finishTurn(.completed)]])
    }
    static let track = Locator.id(StoryID.Composer.context.part(.track))

    static func point(_ what: String, _ point: Int?) -> Expect {
        Expect(what, found: { story in story.app.chat.map { $0.context.autoCompactAt.map { "\($0)%" } ?? "Off" } }) { story in
            try story.activeChat().context.autoCompactAt == point
        }
    }

    var opening: [any Step] {
        super.steps() + [
            Send("Read the folder"), TurnFinished(1), WaitIdle(),
            Do("open the context card") { try $0.activeChat().storyOpenContextCard() },
            WaitForElement(Self.track),
        ]
    }
}

/// A drag along the track sets the auto-compact point at the snap nearest where it ends.
final class DriveContextTrackDrag: DriveContextTrack {
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        opening + [
            Drag(Self.track, by: { _ in
                guard let frame = StoryElement(StoryID.Composer.context.part(.track))?.frame else { throw StoryFailure.modelMissing("the track") }
                return CGVector(dx: frame.width * 0.2, dy: 0)
            }),
            Self.point("dragged from the middle a fifth on: 70%", 70),
        ]
    }
}

/// The track's keys: → and ← step the point between the snaps, Delete turns it off.
final class DriveContextTrackKeys: DriveContextTrack {
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        opening + [
            Click(Self.track),
            Self.point("a click in the middle: 50%", 50),
            Key(.right),
            Self.point("→ one snap on: 60%", 60),
            Key(.left),
            Self.point("← one snap back: 50%", 50),
            Key(KeyChord(.backspace)),
            Self.point("Delete: off", nil),
        ]
    }
}
