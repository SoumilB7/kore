import AppKit
import Testing

@testable import KoreUI

/// Every question is answered, and the one after it is asked, whatever became of its window.
@MainActor @Suite(.serialized) struct KoreAskQueueTests {
    private final class Seen {
        var asked: [String] = []
        var answered: [String] = []
        var front: NSWindow?
    }

    private func question(_ key: String) -> AskQuestion {
        AskQuestion(title: key, choices: [AskChoice("Cancel", .cancel), AskChoice("Go", .accent)], preferred: 1, key: key)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func asking(_ seen: Seen) -> KoreAsk {
        _ = NSApplication.shared
        let ask = KoreAsk()
        ask.frontWindow = { seen.front }
        ask.windowless = {
            seen.asked.append($0.key)
            return AskAnswer(choice: 1, text: "", ticked: false)
        }
        return ask
    }

    private func start(_ ask: KoreAsk, _ key: String, in window: NSWindow?, _ seen: Seen) -> Task<AskAnswer?, Never> {
        Task {
            let answer = await ask.ask(question(key), in: window)
            seen.answered.append(key)
            return answer
        }
    }

    /// Runs the main actor's other work until `done`, or it's had its turns.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
    }

    @Test func aWindowlessAnswerWakesTheNext() async {
        let seen = Seen(), ask = asking(seen), window = window()
        seen.front = window
        let first = start(ask, "first", in: window, seen)
        await settle { ask.question?.key == "first" }
        let second = start(ask, "second", in: nil, seen), third = start(ask, "third", in: nil, seen)
        for _ in 0..<20 { await Task.yield() }
        seen.front = nil
        window.close()
        await settle { seen.answered.count == 3 }
        #expect(seen.answered == ["first", "second", "third"])
        #expect(seen.asked == ["second", "third"])
        guard seen.answered.count == 3 else { return }
        #expect(await first.value?.choice == 0)
        #expect(await second.value?.choice == 1)
        #expect(await third.value?.choice == 1)
    }

    @Test func aQuestionSettledMeanwhileAsksNothingAndWakesTheNext() async {
        let seen = Seen(), ask = asking(seen), window = window()
        seen.front = window
        let first = start(ask, "first", in: window, seen)
        await settle { ask.question?.key == "first" }
        let none = Task { () -> AskAnswer? in
            let answer = await ask.ask(in: window) { nil }
            seen.answered.append("none")
            return answer
        }
        for _ in 0..<20 { await Task.yield() }
        let last = start(ask, "last", in: window, seen)
        for _ in 0..<20 { await Task.yield() }
        ask.answer(1)
        await settle { ask.question?.key == "last" }
        #expect(ask.question?.key == "last")
        ask.answer(1)
        await settle { seen.answered.count == 3 }
        #expect(Set(seen.answered) == ["first", "none", "last"])
        guard seen.answered.count == 3 else { return }
        #expect(await first.value?.choice == 1)
        #expect(await none.value == nil)
        #expect(await last.value?.choice == 1)
    }

    @Test func aClosedWindowIsNotAskedIn() async {
        let seen = Seen(), ask = asking(seen), gone = window(), open = window()
        seen.front = open
        gone.close()
        let task = start(ask, "asked", in: gone, seen)
        await settle { ask.question != nil }
        #expect(ask.question?.key == "asked")
        #expect(open.contentView?.subviews.isEmpty == false)
        #expect(gone.contentView?.subviews.isEmpty == true)
        ask.answer(1)
        await settle { !seen.answered.isEmpty }
        guard !seen.answered.isEmpty else { return }
        #expect(await task.value?.choice == 1)
    }
}
