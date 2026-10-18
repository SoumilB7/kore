import KoreUI

/// One popup over the composer at a time: the / menu goes when the model chip is pressed,
/// Usage when the mode chip is, Account when "/" is typed, the context card when the / key
/// is pressed, and the / menu again on a press of the context wheel.
final class OnePopup: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let menu = Locator.id(StoryID.Composer.command("usage"))
        let slash = Locator.id(StoryID.Composer.slash)
        return super.steps() + [
            Send("Hello"), TurnFinished(1),
            WaitForFocus(.id(StoryID.Composer.field)),

            Press(slash), WaitForElement(menu),
            Press(.id(StoryID.Composer.model)),
            ExpectElement(menu, .absent),
            Key(KeyChord(.backspace)),

            Press(slash), Press(menu),
            Expect("Usage open") { try $0.activeChat().isUsageOpen },
            Press(.id(StoryID.Composer.mode)),
            Expect("Usage closed") { try !$0.activeChat().isUsageOpen },

            Press(slash), Press(.id(StoryID.Composer.command("account"))),
            Expect("Account open") { try $0.activeChat().isAccountOpen },
            WaitForFocus(.id(StoryID.Composer.field)),
            TypeText("/"), WaitForElement(menu),
            Expect("Account closed under the / menu") { try !$0.activeChat().isAccountOpen },
            Key(.escape), Key(KeyChord(.backspace)),

            Expect("the context card open") { story in
                let chat = try story.activeChat()
                chat.storyOpenContextCard()
                return chat.isContextCardOpen
            },
            Press(slash), WaitForElement(menu),
            Expect("the card closed under the / menu") { try !$0.activeChat().isContextCardOpen },

            // A real press on the bar, as a chip's menu opens: the context wheel's (it compacts).
            Click(.id(StoryID.Composer.context)),
            ExpectElement(menu, .absent),
            Expect("the compaction over") { story in
                try !story.activeChat().isCompacting
                    && story.chatEvents().contains { if case .compacted = $0 { true } else { false } }
            },
        ]
    }
}
