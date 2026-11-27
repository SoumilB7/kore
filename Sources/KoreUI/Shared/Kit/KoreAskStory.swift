import AppKit

extension KoreAsk {
    /// Storylines: a plain question in `window`, as the app asks one; `done` hears the answer.
    package static func storyAsk(_ key: String, in window: NSWindow?, _ done: @escaping @MainActor (Int) -> Void) {
        Task { @MainActor in
            let question = AskQuestion(title: "Go on?", choices: [AskChoice("Cancel", .cancel), AskChoice("Go on", .accent)], preferred: 1, key: key)
            done(await shared.ask(question, in: window).choice)
        }
    }
}
