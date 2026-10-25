import AppKit
import KoreCore
import Observation

/// New tab's install card (cli-install.html): the CLI it's for and the tab it opened in, and
/// where it is: offered, installing, installed, or failed with one reason. App-wide, so an
/// install runs on whatever happens to the tab; one at a time. It only installs: signing in
/// stays in Account.
@MainActor @Observable
package final class CLIInstalls {
    package static let shared = CLIInstalls()

    enum Phase: Equatable {
        case offer
        case installing(CLIInstaller.Progress)
        case installed
        case failed(CLIInstaller.Reason)
    }

    struct Card: Equatable {
        let provider: String
        let tab: UUID
        var phase: Phase
    }

    private(set) var card: Card?
    /// The ways this Mac can install, read when a card first opens.
    private(set) var methods: [CLIInstaller.Method] = [.official]
    /// How long "✓ … installed" stays before the bar folds back.
    static let installedFor: Duration = .milliseconds(1600)

    @ObservationIgnored private var method: CLIInstaller.Method = .official
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var methodsRead = false

    func card(for tab: UUID) -> Card? { card?.tab == tab ? card : nil }

    var installing: Bool {
        if case .installing = card?.phase { true } else { false }
    }

    /// A missing CLI clicked in New tab: its card opens there (a second click closes it). Not
    /// while an install runs.
    func offer(_ provider: String, in tab: UUID) {
        guard !installing else { return }
        if card?.provider == provider, card?.tab == tab {
            card = nil
            return
        }
        card = Card(provider: provider, tab: tab, phase: .offer)
        UILog.event("install-offer", ["cli": provider])
        guard !methodsRead else { return }
        methodsRead = true
        Task { methods = await CLIInstaller.methods() }
    }

    /// Cancel: an install under way stops and the card stays, offering again; otherwise it closes.
    func cancel() {
        if installing {
            run?.cancel()
        } else {
            card = nil
        }
    }

    func install(_ method: CLIInstaller.Method) {
        guard let provider = card?.provider, !installing else { return }
        self.method = method
        card?.phase = .installing(CLIInstaller.Progress())
        run = Task { [weak self] in
            do {
                try await CLIInstaller.install(provider, method: method) { progress in
                    Task { @MainActor in self?.moved(provider, progress) }
                }
                await self?.found(provider)
            } catch is CancellationError {
                self?.ended(provider, .offer)
            } catch {
                self?.ended(provider, .failed(error as? CLIInstaller.Reason ?? .other))
            }
        }
    }

    /// Try again: the way that failed, again.
    func retry() { install(method) }

    /// Copy command: the failed way's command, to run in a terminal.
    func copyCommand() {
        guard let provider = card?.provider, let command = CLIInstaller.command(method, for: provider) else { return }
        AccountStore.shared.copy(command)
        UILog.event("install-copy", ["cli": provider])
    }

    /// Locate…: a binary picked by hand becomes the CLI's, kept across runs, once it answers.
    func locate() {
        guard let provider = card?.provider, !installing else { return }
        let picked: URL?
        if StoryHost.installed {
            picked = StorylineSeams.chooseFile?()
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = true
            panel.showsHiddenFiles = true
            panel.prompt = "Use"
            picked = panel.runModal() == .OK ? panel.url : nil
        }
        guard let picked else { return }
        UILog.event("install-locate", ["cli": provider])
        Task {
            CLIExecutable.choose(provider, picked)
            guard await CLIExecutable.located(provider)?.path == picked.path else {
                CLIExecutable.choose(provider, nil)
                return ended(provider, .failed(.other))
            }
            await AccountStore.shared.refresh(provider)
            if card?.provider == provider { card = nil }
        }
    }

    private func moved(_ provider: String, _ progress: CLIInstaller.Progress) {
        guard card?.provider == provider, installing else { return }
        card?.phase = .installing(progress)
    }

    /// The installer finished: Kore looks again from scratch (no restart), reads the CLI's status
    /// so the bar shows it installed, says so for a moment, then folds back.
    private func found(_ provider: String) async {
        moved(provider, CLIInstaller.Progress(stage: .finishing))
        CLIExecutable.invalidate()
        guard await CLIExecutable.located(provider) != nil else { return ended(provider, .failed(.other)) }
        await AccountStore.shared.refresh(provider)
        ended(provider, .installed)
        try? await Task.sleep(for: Self.installedFor)
        if card?.provider == provider, card?.phase == .installed { card = nil }
    }

    private func ended(_ provider: String, _ phase: Phase) {
        run = nil
        guard card?.provider == provider else { return }
        card?.phase = phase
    }

    /// The card's state in words, for storylines: "offer", "installing: <stage line>",
    /// "installed", "failed: <reason>"; nil with no card.
    package var storyState: String? {
        switch card?.phase {
        case nil: nil
        case .offer: "offer"
        case .installing(let progress): "installing: " + progress.text
        case .installed: "installed"
        case .failed(let reason): "failed: " + reason.text
        }
    }

    /// Back to nothing open (a storyline's start).
    func reset() {
        run?.cancel()
        run = nil
        card = nil
        methodsRead = false
        methods = [.official]
    }
}
