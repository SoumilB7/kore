import AppKit
import SwiftUI

/// One answer a question offers. `cancel` is what Esc and a click beside the card pick; `danger`
/// is drawn red (it ends or loses something); `accent` is the one the question leans to.
@MainActor
struct AskChoice {
    enum Role { case plain, cancel, danger, accent }
    let title: String
    var role: Role = .plain

    init(_ title: String, _ role: Role = .plain) {
        self.title = title
        self.role = role
    }
}

/// What Kore asks, in its own card over the window instead of a macOS alert: a line, a note
/// under it, an optional field (a new name) and tick ("Apply to all"), and its answers.
@MainActor
struct AskQuestion {
    var title: String
    var detail: String?
    var choices: [AskChoice]
    /// The answer Return picks, ringed until Tab moves it.
    var preferred: Int
    /// A field's first text (a rename): nil for none.
    var field: String?
    var fieldPrompt = ""
    var tick: String?
    /// Its name in logs and storylines ("trash", "rename-chat").
    var key: String
}

struct AskAnswer: Equatable {
    let choice: Int
    let text: String
    let ticked: Bool
}

/// Kore's own question over a window: the page dimmed under one card, centred, with the accent's
/// corner marks as the option popups have. One at a time (a second waits for the first), and
/// any open option popup closes for it. Esc or a click beside the card cancels; Return picks the
/// ringed answer, Tab and the arrows move the ring. While it's up, the window behind takes no
/// keys or clicks, as an alert's would not.
@MainActor @Observable
package final class KoreAsk {
    package static let shared = KoreAsk()

    private(set) var question: AskQuestion?
    package var text = ""
    package var ticked = false
    /// The ringed answer.
    private(set) var ring = 0

    @ObservationIgnored private weak var owner: NSWindow?
    @ObservationIgnored private weak var returnResponder: NSResponder?
    @ObservationIgnored private var host: NSView?
    @ObservationIgnored private var monitor: Any?
    /// Windows that closed: a closed one can live on, its content with it (whatever holds it).
    @ObservationIgnored private let closed = NSHashTable<NSWindow>.weakObjects()
    /// Tests: the window to ask in, and what asks with none.
    @ObservationIgnored var frontWindow: @MainActor () -> NSWindow? = KoreAsk.front
    @ObservationIgnored var windowless: @MainActor (AskQuestion) -> AskAnswer = KoreAsk.alert
    @ObservationIgnored private var answering: CheckedContinuation<AskAnswer, Never>?
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Made at launch (`AppDelegate`), before any window: while a card is up its window's keys and
    /// presses are the card's, not the tabs' or the chat's (monitors aren't run in a fixed order,
    /// so those that act on a window's keys also ask `holds`). It also has to have seen a window
    /// close to know not to ask in it.
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, question != nil else { return event }
            return handle(event)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowClosed(window) }
        }
    }

    func windowClosed(_ window: NSWindow?) {
        guard let window else { return }
        closed.add(window)
        if window === owner { cancel() }
    }

    /// A window a card can be seen in: not a closed one (shown again, it's open again).
    private func canAsk(in window: NSWindow) -> Bool {
        window.contentView != nil && (window.isVisible || !closed.contains(window))
    }

    /// A question is up.
    package var isOpen: Bool { question != nil }
    /// A question is up over `window`: its keys are the card's.
    func holds(_ window: NSWindow) -> Bool { question != nil && owner === window }
    /// Storylines: the key of the question up now.
    package static var storyOpen: String? { shared.question?.key }
    /// Storylines: the question's line, and its answers' words.
    package static var storyTitle: String? { shared.question?.title }
    package static var storyChoices: [String] { shared.question?.choices.map(\.title) ?? [] }

    /// Asks in `window` (else the front one) and waits for the answer. With no window at all to
    /// ask in (every one closed while work runs), macOS's alert asks instead: never unasked, never
    /// stuck.
    func ask(_ question: AskQuestion, in window: NSWindow? = nil) async -> AskAnswer {
        await ask(in: window) { question } ?? AskAnswer(choice: Self.cancelIndex(question), text: question.field ?? "", ticked: false)
    }

    /// The same, the question made when its turn comes (one before it may have settled it): nil
    /// asks nothing. A window that closed meanwhile isn't asked in: the front one is.
    func ask(in window: NSWindow? = nil, _ make: () -> AskQuestion?) async -> AskAnswer? {
        // A storyline host answering instead (`StorylineSeams.confirm`): yes is the preferred.
        if let seam = StorylineSeams.confirm {
            return make().map { AskAnswer(choice: seam($0.key) ? $0.preferred : Self.cancelIndex($0), text: $0.field ?? "", ticked: false) }
        }
        while isOpen { await withCheckedContinuation { waiting.append($0) } }
        // Whatever ends this without a card wakes the next in line, as an answer does.
        guard let question = make() else { wakeNext(); return nil }
        guard let window = window.flatMap({ canAsk(in: $0) ? $0 : nil }) ?? frontWindow(), canAsk(in: window), let content = window.contentView else {
            let answer = windowless(question)
            wakeNext()
            return answer
        }
        // Put away in the Dock, its card couldn't be seen.
        if window.isMiniaturized { window.deminiaturize(nil) }
        OptionsMenu.shared.close()
        self.question = question
        text = question.field ?? ""
        ticked = false
        ring = question.preferred
        owner = window
        returnResponder = window.firstResponder
        let host = NSHostingView(rootView: AskOverlay(ask: self))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityRole(.sheet)
        content.addSubview(host)
        self.host = host
        if question.field == nil { window.makeFirstResponder(host) }
        UILog.event("ask-open", ["key": question.key])
        return await withCheckedContinuation { answering = $0 }
    }

    /// Picks answer `index`.
    func answer(_ index: Int) {
        guard let question, let answering, question.choices.indices.contains(index) else { return }
        let result = AskAnswer(choice: index, text: text, ticked: ticked)
        UILog.event("ask-answer", ["key": question.key, "choice": question.choices[index].title])
        self.answering = nil
        close()
        answering.resume(returning: result)
        wakeNext()
    }

    private func wakeNext() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }

    func cancel() {
        guard let question else { return }
        answer(Self.cancelIndex(question))
    }

    func toggleTick() { ticked.toggle() }

    /// Storylines: a question one left up, answered with its cancel so the next starts clear; its key.
    package static func storyCancelLeftOpen() -> String? {
        guard let key = shared.question?.key else { return nil }
        shared.cancel()
        return key
    }

    private func close() {
        host?.removeFromSuperview()
        host = nil
        if let owner, let view = returnResponder as? NSView, view.window === owner { owner.makeFirstResponder(view) }
        owner = nil
        returnResponder = nil
        question = nil
    }

    private func moveRing(_ step: Int) {
        guard let count = question?.choices.count, count > 0 else { return }
        ring = (ring + step + count) % count
    }

    /// The window behind takes nothing while it's up; keys go to the card (and its field).
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let owner, let question else { return event }
        guard event.window === owner else { return event }
        switch event.type {
        case .keyDown:
            switch event.keyCode {
            case 53: cancel(); return nil
            case 36, 76:
                // Return alone: held with ⌘, ⇧, ⌥ or ⌃ it's another key, and answers nothing.
                if event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) { answer(ring) }
                return nil
            case 48: moveRing(event.modifierFlags.contains(.shift) ? -1 : 1); return nil
            case 123 where question.field == nil, 124 where question.field == nil: moveRing(event.keyCode == 123 ? -1 : 1); return nil
            case 49 where question.field == nil: answer(ring); return nil
            default: break
            }
            // Typing goes to the field, with its editing keys; nothing reaches the window's menus.
            guard question.field != nil else { return nil }
            let command = event.modifierFlags.contains(.command)
            if command, !["c", "v", "x", "a", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return nil }
            return event
        case .scrollWheel:
            return nil
        default:
            // A press on the card is its own; beside it, the window's isn't reached (the dimmed
            // page takes it and cancels).
            return event
        }
    }

    /// The windowless fallback: the same question in macOS's alert.
    private static func alert(_ question: AskQuestion) -> AskAnswer {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail ?? ""
        // The preferred answer first (Return), the rest after it.
        let order = [question.preferred] + question.choices.indices.filter { $0 != question.preferred }
        for index in order {
            let button = alert.addButton(withTitle: question.choices[index].title)
            button.hasDestructiveAction = question.choices[index].role == .danger
        }
        let field = question.field.map { text -> NSTextField in
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            alert.accessoryView = field
            return field
        }
        if let tick = question.tick {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = tick
        }
        let picked = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = order.indices.contains(picked) ? order[picked] : cancelIndex(question)
        return AskAnswer(choice: index, text: field?.stringValue ?? question.field ?? "", ticked: alert.suppressionButton?.state == .on)
    }

    static func cancelIndex(_ question: AskQuestion) -> Int {
        question.choices.firstIndex { $0.role == .cancel } ?? max(question.choices.count - 1, 0)
    }

    /// The window to ask in: the key one, else the main one, else the front visible one.
    static func front() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
    }
}

// MARK: - Shorthands

extension KoreAsk {
    /// Yes (`yes`, red when it `danger`s) or Cancel.
    static func confirm(_ title: String, detail: String? = nil, yes: String, danger: Bool = false, cancelFirst: Bool = false,
                        key: String, in window: NSWindow? = nil) async -> Bool {
        let choices = cancelFirst
            ? [AskChoice("Cancel", .cancel), AskChoice(yes, danger ? .danger : .accent)]
            : [AskChoice(yes, danger ? .danger : .accent), AskChoice("Cancel", .cancel)]
        let yesIndex = cancelFirst ? 1 : 0
        // A question that loses work leans to Cancel.
        let preferred = danger && cancelFirst ? 0 : yesIndex
        let answer = await shared.ask(AskQuestion(title: title, detail: detail, choices: choices, preferred: preferred, key: key), in: window)
        return answer.choice == yesIndex
    }

    /// A line to read, and OK.
    static func tell(_ title: String, detail: String? = nil, key: String, in window: NSWindow? = nil) async {
        _ = await shared.ask(AskQuestion(title: title, detail: detail, choices: [AskChoice("OK", .accent)], preferred: 0, key: key), in: window)
    }

    /// A new name in a field: nil when cancelled or left empty.
    static func name(_ title: String, current: String, prompt: String = "Name", action: String = "Rename",
                     key: String, in window: NSWindow? = nil) async -> String? {
        let answer = await shared.ask(
            AskQuestion(title: title, choices: [AskChoice("Cancel", .cancel), AskChoice(action, .accent)], preferred: 1,
                        field: current, fieldPrompt: prompt, key: key),
            in: window)
        let name = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.choice == 1 && !name.isEmpty ? name : nil
    }

    enum SaveAnswer { case save, discard, cancel }

    /// Save (all), Don't Save, or Cancel, before edits are lost.
    /// `names`: the files still unsaved when its turn comes; none, and nothing's asked (discard:
    /// there's nothing to lose).
    static func saveChanges(_ names: () -> [String], key: String, in window: NSWindow? = nil) async -> SaveAnswer {
        let answer = await shared.ask(in: window) {
            let names = names()
            guard !names.isEmpty else { return nil }
            let title = names.count == 1
                ? "Do you want to save the changes you made to \(names[0])?"
                : "Do you want to save the changes you made to \(names.count) files?"
            let choices = [AskChoice("Don't Save", .danger), AskChoice("Cancel", .cancel), AskChoice(names.count == 1 ? "Save" : "Save All", .accent)]
            return AskQuestion(title: title, detail: "Your changes will be lost if you don't save them.", choices: choices, preferred: 2, key: key)
        }
        guard let answer else { return .discard }
        return switch answer.choice {
        case 2: .save
        case 0: .discard
        default: .cancel
        }
    }
}

// MARK: - The card

private struct AskOverlay: View {
    let ask: KoreAsk
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Theme.background.opacity(Size.Ask.scrim)
                .contentShape(Rectangle())
                .onTapGesture { ask.cancel() }
                .accessibilityHidden(true)
                .storyAction(StoryID.Ask.scrim) { ask.cancel() }
            if let question = ask.question { card(question) }
        }
    }

    private func card(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(question.title)
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail, !detail.isEmpty {
                Text(detail)
                    .font(Chrome.label)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.field != nil {
                TextField("", text: Binding(get: { ask.text }, set: { ask.text = $0 }),
                          prompt: Text(question.fieldPrompt).foregroundStyle(Theme.tertiary))
                    .focused($fieldFocused)
                    .fieldWell(focused: fieldFocused)
                    .onAppear { fieldFocused = true }
                    .accessibilityLabel(Text(question.fieldPrompt))
                    .storyID(StoryID.Ask.field)
            }
            if let tick = question.tick {
                Button { ask.toggleTick() } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: ask.ticked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(ask.ticked ? Theme.accent : Theme.secondary)
                        Text(tick).foregroundStyle(Theme.text)
                    }
                    .font(Chrome.label)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(ask.ticked ? .isSelected : [])
                .storyID(StoryID.Ask.tick, press: { ask.toggleTick() })
            }
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                    Button(choice.title) { ask.answer(index) }
                        .smallButton(prominent: choice.role == .accent, danger: choice.role == .danger)
                        .overlay {
                            if ask.ring == index {
                                RoundedRectangle(cornerRadius: Radius.chip)
                                    .strokeBorder(Theme.accentLine, lineWidth: Stroke.emphasis)
                                    .allowsHitTesting(false)
                            }
                        }
                        .storyID(StoryID.Ask.choice(choice.title), press: { ask.answer(index) })
                }
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.lg)
        .frame(width: Size.Ask.width, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(question.title))
        .storyID(StoryID.Ask.card)
    }
}

extension StoryID.Ask {
    /// The dimmed page around the card: a click there cancels.
    package static let scrim = StoryID(.ask, "scrim")
}
