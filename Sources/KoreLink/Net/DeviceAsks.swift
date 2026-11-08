import Foundation
import KoreUI

/// The owner's answers to devices asking this Mac (phase 18 §1 "Allow flow"): a phone joining
/// from the Add device window, and a phone's new fingerprint key. One card at a time, the rest in
/// line; each is answered Allow, Deny, or after `wait` unanswered, timed out (as Deny). A device
/// that gives up takes its card away.
@MainActor
package final class DeviceAsks {
    package enum Answer: Equatable, Sendable { case allow, deny, timeout, gone }

    package final class Ask {
        package let info: DeviceCardInfo
        fileprivate let done: @MainActor (Answer) -> Void
        fileprivate var cancelTimer: (() -> Void)?
        fileprivate var answered = false

        fileprivate init(info: DeviceCardInfo, done: @escaping @MainActor (Answer) -> Void) {
            self.info = info
            self.done = done
        }
    }

    /// How long a card waits for the owner (the phone waits 120 s for its welcome).
    package static var wait: TimeInterval = 100

    /// Shows a card (Kore: `LinkPanel.showDeviceCard`; tests: their own).
    package var present: @MainActor (DeviceCardInfo, @escaping @MainActor (Bool) -> Void) -> Void = { info, answer in
        LinkPanel.showDeviceCard(info) { allow in MainActor.assumeIsolated { answer(allow) } }
    }
    /// The device went, or the owner didn't answer in time: the card says it stopped waiting.
    package var dismiss: @MainActor () -> Void = { LinkPanel.deviceStoppedWaiting() }
    /// Runs `work` after `seconds`; the closure it gives back cancels it (tests: a hand clock).
    package var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { seconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }

    private var line: [Ask] = []
    package private(set) var showing: Ask?

    package init() {}

    /// Asks the owner; `done` is called once.
    @discardableResult
    package func ask(_ info: DeviceCardInfo, done: @escaping @MainActor (Answer) -> Void) -> Ask {
        let ask = Ask(info: info, done: done)
        ask.cancelTimer = schedule(Self.wait) { [weak self, weak ask] in
            guard let self, let ask else { return }
            self.finish(ask, .timeout)
        }
        line.append(ask)
        showNext()
        return ask
    }

    /// The device went before the owner answered.
    package func cancel(_ ask: Ask) { finish(ask, .gone) }

    /// The owner's answer to the card showing (the card's buttons; tests).
    package func answer(_ allow: Bool) {
        guard let showing else { return }
        finish(showing, allow ? .allow : .deny, fromCard: true)
    }

    /// Cards waiting, the one showing first.
    package var waiting: Int { line.count }

    private func showNext() {
        guard showing == nil, let next = line.first else { return }
        showing = next
        present(next.info) { [weak self, weak next] allow in
            guard let self, let next else { return }
            self.finish(next, allow ? .allow : .deny, fromCard: true)
        }
    }

    private func finish(_ ask: Ask, _ answer: Answer, fromCard: Bool = false) {
        guard !ask.answered else { return }
        ask.answered = true
        ask.cancelTimer?()
        ask.cancelTimer = nil
        line.removeAll { $0 === ask }
        if showing === ask {
            showing = nil
            if !fromCard { dismiss() }
        }
        ask.done(answer)
        showNext()
    }
}
