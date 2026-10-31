import Foundation
import KoreRemote
import KoreUI

/// Phone on and off, the Mac's mailbox on the relay, and pairing. Kore listens on nothing: it
/// dials the relay, which forwards encrypted bytes between it and a paired phone. One run of
/// Kore, one key, one mailbox; Phone off or quit forgets them all.
@MainActor
package final class PhoneService {
    /// The relay's host (`phone.relay` in Kore's defaults); nil until it's set up.
    package static var relayHost: String? {
        get { relayOverride ?? UserDefaults.standard.string(forKey: "phone.relay").flatMap { $0.isEmpty ? nil : $0 } }
        set { relayOverride = newValue }
    }
    private static var relayOverride: String?
    /// How the relay is reached; a storyline or test gives the loopback relay's.
    package static var dialer: RelayDialer?
    /// The Mac's name, as phones show it.
    package static let macName = Host.current().localizedName ?? "Mac"

    private unowned let host: RemoteHost
    private var gate: RemoteGate?
    private var relay: RelayHost?
    private var gateEvents: Task<Void, Never>?
    private var sleepWatch: SleepWatch?
    private var network: NSObjectProtocol?
    /// The last QR's contents, for a storyline's phone (which can't scan).
    package private(set) var lastOffer: PairingCode?

    init(host: RemoteHost) { self.host = host }

    private var model: PhoneModel { host.phone }

    // MARK: On and off

    /// Phone on: a new key and mailbox for this run, the mailbox opened on the relay.
    package func enable() {
        guard gate == nil else { return }
        guard let dial = Self.dialer ?? Self.relayHost.map(WebSocketRelay.dialer(host:)) else {
            model.relay = .notSetUp
            return
        }
        host.turnOn()
        let gate = RemoteGate(macName: Self.macName)
        let relay = RelayHost(
            dial: dial, onPhone: { channel in Task { await gate.accept(channel) } },
            onStatus: { [weak self] status in Task { @MainActor in self?.model.relay = .init(status) } })
        self.gate = gate
        self.relay = relay
        model.isOn = true
        gateEvents = Task { [weak self] in
            for await event in gate.stream { await self?.gateEvent(event, relay: relay) }
        }
        sleepWatch = SleepWatch(
            sleep: { [weak self] in self?.sleep() }, wake: { [weak self] in self?.wake() }, quit: { [weak self] in self?.disable(.quit) })
        network = NotificationCenter.default.addObserver(forName: NetworkWatch.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        Task { await relay.start() }
        model.note("Phone on")
    }

    /// Phone off (or quit): every phone told, the mailbox closed, every pairing forgotten.
    package func disable(_ reason: Record.ByeReason = .off) {
        guard let gate else { return }
        let relay = relay
        Task {
            await gate.shutdown(reason)
            // The phones' goodbyes go out before the mailbox closes.
            try? await Task.sleep(for: .milliseconds(200))
            await relay?.stop()
        }
        self.gate = nil
        self.relay = nil
        gateEvents?.cancel()
        gateEvents = nil
        sleepWatch?.stop()
        sleepWatch = nil
        if let network { NotificationCenter.default.removeObserver(network) }
        network = nil
        lastOffer = nil
        model.reset()
        model.note("Phone off")
        host.turnOff()
    }

    /// Sleep: phones are told; the pairings stay for the wake.
    private func sleep() {
        guard let gate else { return }
        Task { await gate.sleep() }
    }

    /// Awake again, or the network changed: back to the relay now.
    private func wake() {
        guard let relay else { return }
        Task { await relay.nudge() }
    }

    // MARK: Pairing

    /// A QR for a phone to scan: one at a time, 60 s, once.
    package func startPairing() {
        lastOffer = nil
        guard let gate, let relay, case .connected = model.relay, let relayHost = Self.relayHost ?? (Self.dialer != nil ? "loopback" : nil) else { return }
        Task {
            do {
                let code = try await gate.makeOffer(relay: relayHost, mailbox: relay.mailbox)
                lastOffer = code
                model.pairing = .code(code.text, until: Date().addingTimeInterval(RemoteGate.offerLife))
            } catch RemoteGate.Failure.tooManyPhones {
                model.pairing = .failed("Two phones are paired: remove one first.")
            } catch {
                model.pairing = .failed("Pairing couldn't start.")
            }
        }
    }

    package func cancelPairing() {
        guard let gate else { return }
        Task { await gate.cancelOffer() }
        model.pairing = .none
    }

    /// The owner typed the code the phone shows.
    package func submitCode(_ code: String) {
        guard let gate else { return }
        Task {
            switch await gate.submit(code) {
            case .accepted: model.pairing = .none
            case .wrong:
                if case .typing(let p, _) = model.pairing { model.pairing = .typing(p, wrong: true) }
            case .refused: model.pairing = .failed("Not paired.")
            }
        }
    }

    package func denyPairing() {
        guard let gate else { return }
        Task { await gate.deny() }
        model.pairing = .none
    }

    package func remove(_ id: String) {
        guard let gate else { return }
        Task { await gate.remove(id) }
    }

    package func disconnect(_ id: String) {
        guard let gate else { return }
        Task { await gate.disconnect(id) }
    }

    // MARK: The gate's news

    private func gateEvent(_ event: RemoteGate.Event, relay: RelayHost) async {
        switch event {
        case .allowToken(let hash): await relay.allow(hash)
        case .revokeToken(let hash): await relay.revoke(hash)
        case .prompt(let prompt?): model.pairing = .typing(prompt, wrong: false)
        case .prompt(nil):
            if case .typing = model.pairing { model.pairing = .none }
        case .offerEnded:
            if case .code = model.pairing { model.pairing = .none }
        case .phones(let records): model.rows = host.rows(records)
        case .link(let link, let record):
            host.connect(link, phoneID: record.id)
            host.refreshRows()
        case .activity(let event, let id):
            let name = id.flatMap { id in model.rows.first { $0.id == id }?.name }
            if let text = PhoneActivity.text[event] { model.note(text, phone: name) }
        }
    }
}
