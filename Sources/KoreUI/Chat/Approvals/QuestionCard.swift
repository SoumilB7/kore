import AppKit
import src
import SwiftUI

/// The CLI's questions (question-card.html, B "Steps"): one at a time, under tabs named by the
/// CLI's short headers with a tick on each answered one. A single question has no tabs; a card
/// too narrow for them steps through them, "2/4 ‹ ›". The body is as tall as the tallest
/// question, so a switch never moves the card or the composer; past half the window it scrolls
/// with its scrollbar, never a fade. A pick is its radio or checkbox and a thin accent line round
/// its row; Other is the last row, the row its field. Nothing goes until Submit, which waits for
/// every answer; until then, an answered question's button is Next, to the next one unanswered.
/// Skip, beside it, turns the questions down unanswered.
///
/// The card has the keys as it arrives over an empty composer, and once clicked (its corner
/// marks say so): ↑ ↓ move the current row, as the pointer does; Space picks; ↩ picks and goes
/// on to the next unanswered question; 1–4 pick an option and the number after them is Other;
/// ⇥ ⇧⇥ go between questions; ⌘↩ submits; Esc leaves Other's field, then gives the keys back
/// to the composer.
struct QuestionCard: View {
    let approval: Approval
    var maxHeight: CGFloat = .infinity
    /// The composer is empty as the card arrives: the card takes the keys.
    var composerEmpty: () -> Bool = { true }
    /// Gives the keys to the composer (true), or takes them from it (false).
    var composerKeys: (Bool) -> Void = { _ in }
    /// Skip: the questions turned down unanswered, as the link's Skip does (`.deny`).
    let skip: () -> Void
    let submit: ([String: [String]]) -> Void
    /// The options picked, Other's and what's typed under it.
    @StateObject private var picks = Local(QuestionPicks())
    /// The question shown, and its current row (an option's place; Other's is after them).
    @StateObject private var page = Local(0)
    @StateObject private var row = Local<Int?>(nil)
    /// The card has the keys.
    @StateObject private var holding = Local(false)
    @StateObject private var width = Local<CGFloat>(0)
    /// A row the keys moved to, scrolled into view.
    @StateObject private var reveal = Local<String?>(nil)
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)
    /// The question whose Other field has the keys, as the key monitor reads it.
    @StateObject private var editing = Held<String?>(nil)
    @FocusState private var typing: String?

    private var questions: [Approval.Question] { approval.questions }
    private var shownIndex: Int { min(max(page.value, 0), questions.count - 1) }
    private var card: StoryID { StoryID.Approval.card(approval.id) }
    private var ready: Bool { picks.value.complete(questions) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.lg) {
                if questions.count > 1 { strip }
                ScrollViewReader { proxy in
                    ScrollView {
                        pages.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: max(maxHeight - Self.chrome(tabs: questions.count > 1), Size.Question.row * 2))
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollIndicators(.visible)
                    .onChange(of: reveal.value) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                        reveal.value = nil
                    }
                }
            }
            footer
        }
        .padding(Inset.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.card)
        .cornerMarks(Theme.cornerOption, radius: Radius.card, shown: holding.value)
        .background(StoryAnchor(id: holding.value ? card.part(.focus).raw : nil, press: nil))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { now in
            frame.value = now
            width.value = now.width
        }
        .background(WindowReader { window.value = $0 })
        .onChange(of: typing) { _, now in
            editing.value = now
            if now != nil { holding.value = true }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    /// The card's own rows round the questions' body: its padding, the tabs, Submit.
    private static func chrome(tabs: Bool) -> CGFloat {
        Inset.card.top + Inset.card.bottom + Size.iconButton + Space.md + (tabs ? Size.Picker.chip + Space.lg : 0)
    }

    // MARK: Tabs

    /// The tabs, or where they don't fit, the shown one's name and ‹ ›.
    private var strip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(questions.indices, id: \.self) { tab($0) }
            }
            .fixedSize()
            stepper
        }
    }

    private func tab(_ index: Int) -> some View {
        let on = index == shownIndex
        let done = answered(questions[index])
        let id = StoryID.Approval.tab(approval.id, index)
        return Button { go(to: index) } label: {
            HStack(spacing: Space.xs) {
                if done { tick }
                Text(questions[index].tabName(index)).lineLimit(1)
            }
            .font(TextStyle.labelMedium)
            .foregroundStyle(on ? Theme.text : Theme.secondary)
            .padding(.horizontal, Space.lg)
            .frame(height: Size.Picker.chip)
            .background(on ? Theme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .storyID(id)
        .background(StoryAnchor(id: done ? id.part(.done).raw : nil, press: nil))
        .background(StoryAnchor(id: on ? id.part(.lit).raw : nil, press: nil))
    }

    private var stepper: some View {
        let index = shownIndex
        return HStack(spacing: Space.sm) {
            if answered(questions[index]) { tick }
            Text(questions[index].tabName(index))
                .font(TextStyle.labelMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("\(index + 1)/\(questions.count)")
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .fixedSize()
            Spacer(minLength: 0)
            QuestionStepButton(symbol: "chevron.left", label: "Previous question", enabled: index > 0) { go(to: index - 1) }
                .storyID(card.part(.previous))
            QuestionStepButton(symbol: "chevron.right", label: "Next question", enabled: index < questions.count - 1) { go(to: index + 1) }
                .storyID(card.part(.next))
        }
        .padding(.leading, Inset.row.leading)
        .frame(height: Size.Picker.chip)
    }

    /// An answered question's tick.
    private var tick: some View {
        QuestionTick()
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: Stroke.tabTick, lineCap: .round, lineJoin: .round))
            .frame(width: Size.Question.tick, height: Size.Question.tick)
    }

    // MARK: Questions

    /// Every question, stacked, the shown one alone visible: the body is the tallest's height.
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            ForEach(questions.indices, id: \.self) { index in
                let shown = index == shownIndex
                page(questions[index], at: index, shown: shown)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }

    private func page(_ question: Approval.Question, at index: Int, shown: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // On the options' text edge: the tabs', the question's and the labels' are one.
            Text(question.text)
                .font(TextStyle.bodyMedium)
                .lineSpacing(TextStyle.leading)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Inset.row.leading)
            if question.options.isEmpty {
                field(question, shown: shown, well: true)
            } else if question.options.contains(where: { $0.preview != nil }) {
                if width.value >= Size.Question.split {
                    HStack(alignment: .top, spacing: Space.lg) {
                        options(question, at: index, shown: shown).frame(width: splitWidth)
                        preview(question, at: index, shown: shown)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        options(question, at: index, shown: shown)
                        preview(question, at: index, shown: shown)
                    }
                }
            } else {
                options(question, at: index, shown: shown)
            }
        }
    }

    /// The options' side of a wide card with previews.
    private var splitWidth: CGFloat {
        max((width.value - Inset.card.leading - Inset.card.trailing - Space.lg) * Size.Question.splitShare, 0)
    }

    private func options(_ question: Approval.Question, at index: Int, shown: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { place, option in
                optionRow(question, option, place: place, at: index, shown: shown)
            }
            if question.other { otherRow(question, at: index, shown: shown) }
        }
    }

    private func optionRow(_ question: Approval.Question, _ option: Approval.Option, place: Int, at index: Int, shown: Bool) -> some View {
        let on = picks.value.options[question.id]?.contains(option.label) == true
        let current = shown && row.value == place
        let id = StoryID.Approval.option(question.id, option.label)
        return Button { choose(place, in: question) } label: {
            HStack(alignment: .top, spacing: Space.md) {
                QuestionGlyph(multiple: question.multiple, on: on).padding(.top, Size.Question.glyphDrop)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(option.label).font(TextStyle.body).foregroundStyle(Theme.text)
                    if !option.description.isEmpty {
                        Text(option.description).font(TextStyle.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                keyHint(place)
            }
            .optionRow(current: current, on: on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .id(Self.rowID(index, place))
        .highlightRow(shown ? id : nil, lit: current, selects: false) { row.value = place }
        .storyID(shown ? id : nil)
        .background(StoryAnchor(id: shown && on ? id.part(.ticks).raw : nil, press: nil))
    }

    /// Other: a row like the rest; picked, the row is its field: the answer is typed after the
    /// word, on its line, with the row's accent line the only border.
    @ViewBuilder
    private func otherRow(_ question: Approval.Question, at index: Int, shown: Bool) -> some View {
        let open = picks.value.other.contains(question.id)
        let place = question.options.count
        let current = shown && row.value == place
        let id = StoryID.Approval.other(question.id)
        Group {
            if open {
                HStack(alignment: .top, spacing: Space.md) {
                    Button { choose(place, in: question) } label: {
                        HStack(alignment: .top, spacing: Space.md) {
                            QuestionGlyph(multiple: question.multiple, on: true).padding(.top, Size.Question.glyphDrop)
                            // It names the field now.
                            Text("Other").font(TextStyle.body).foregroundStyle(Theme.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .storyID(shown ? id : nil)
                    field(question, shown: shown, well: false)
                    keyHint(place)
                }
                .optionRow(current: current, on: true)
            } else {
                Button { choose(place, in: question) } label: {
                    HStack(spacing: Space.md) {
                        QuestionGlyph(multiple: question.multiple, on: false)
                        Text("Other").font(TextStyle.body).foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        keyHint(place)
                    }
                    .optionRow(current: current, on: false)
                }
                .buttonStyle(.plain)
                .storyID(shown ? id : nil)
            }
        }
        .id(Self.rowID(index, place))
        .highlightRow(shown ? id : nil, lit: current, selects: false) { row.value = place }
        .background(StoryAnchor(id: shown && open ? id.part(.ticks).raw : nil, press: nil))
    }

    /// The line an answer is typed in: Other's, bare in its row, or in a well for a question with
    /// no options, where it has no other border.
    private func field(_ question: Approval.Question, shown: Bool, well: Bool) -> some View {
        // The field writes its text back as it goes (an option picked over Other): that's only
        // the words kept, never Other picked again.
        let text = Binding(get: { picks.value.typed[question.id] ?? "" }, set: { picks.value.typed[question.id] = $0 })
        return Group {
            if question.secret {
                SecureField("", text: text, prompt: Text("Your answer").foregroundStyle(Theme.tertiary))
            } else {
                TextField("", text: text, prompt: Text("Your answer").foregroundStyle(Theme.tertiary), axis: .vertical)
                    .lineLimit(1...6)
            }
        }
        .focused($typing, equals: question.id)
        .modifier(OtherField(well: well, focused: typing == question.id))
        .storyID(shown ? StoryID.Approval.other(question.id).part(.field) : nil)
    }

    /// The row's number while the card has the keys; its room kept always, so nothing reflows.
    private func keyHint(_ place: Int) -> some View {
        Text("\(place + 1)")
            .font(TextStyle.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.tertiary)
            .frame(width: Size.Question.key, alignment: .trailing)
            .opacity(holding.value && place < 9 ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// The current row's preview, else the picked option's, in a well as tall as the tallest.
    private func preview(_ question: Approval.Question, at index: Int, shown: Bool) -> some View {
        let showing = previewed(question, at: index)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                if let text = option.preview {
                    let on = option.label == showing
                    Text(text)
                        .font(TextStyle.code)
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                        .opacity(on ? 1 : 0)
                        .accessibilityHidden(!on)
                        .background(StoryAnchor(id: shown && on ? StoryID.Approval.preview(question.id, option.label).raw : nil, press: nil))
                }
            }
        }
        .padding(Inset.well)
        .frame(minWidth: .zero, maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .panel(.well)
    }

    private func previewed(_ question: Approval.Question, at index: Int) -> String? {
        if index == shownIndex, let place = row.value, question.options.indices.contains(place),
            question.options[place].preview != nil
        {
            return question.options[place].label
        }
        let labels = picks.value.options[question.id] ?? []
        return question.options.first { labels.contains($0.label) && $0.preview != nil }?.label
    }

    /// Skip, then Next while the shown question is answered and another isn't (it goes there, as ↩
    /// does); else Submit, an outline with tertiary words until a press would send.
    private var footer: some View {
        let next = answered(questions[shownIndex]) ? nextUnanswered : nil
        let live = ready || next != nil
        return HStack {
            Spacer(minLength: 0)
            Button(CardLabels.Question.skip, action: skip)
                .buttonStyle(SubtleButtonStyle())
                .storyID(card.part(.deny))
            Button {
                if let next { go(to: next) } else { send() }
            } label: {
                Text(next != nil ? "Next" : CardLabels.Question.submit).foregroundStyle(live ? Theme.background : Theme.tertiary)
            }
            .buttonStyle(SubtleButtonStyle(prominent: live))
            .disabled(!live)
            .storyID(card.part(.submit))
            .background(StoryAnchor(id: next != nil ? card.part(.continue).raw : nil, press: nil))
        }
        .background(StoryAnchor(id: ready ? card.part(.done).raw : nil, press: nil))
    }

    private static func rowID(_ page: Int, _ place: Int) -> String { "\(page)/\(place)" }

    // MARK: Picking

    private func rows(_ question: Approval.Question) -> Int {
        question.options.count + (question.other && !question.options.isEmpty ? 1 : 0)
    }

    private func answered(_ question: Approval.Question) -> Bool {
        picks.value.answered(question)
    }

    /// A row picked, by a click or a key: an option, or Other (after them).
    private func choose(_ place: Int, in question: Approval.Question) {
        take()
        if question.options.indices.contains(place) {
            picks.value.pick(question.options[place].label, in: question)
            if !picks.value.other.contains(question.id), typing == question.id { typing = nil }
        } else if question.other {
            if picks.value.pickOther(in: question) {
                typing = question.id
            } else if typing == question.id {
                typing = nil
            }
        }
    }

    /// Another question shown; by a key, its first row is current.
    private func go(to index: Int, keyed: Bool = false) {
        guard questions.indices.contains(index) else { return }
        if typing != nil { typing = nil }
        page.value = index
        row.value = keyed && rows(questions[index]) > 0 ? 0 : nil
        if keyed { PointerGate.keyed() }
    }

    /// The next question not yet answered after the shown one, round the end; nil when every
    /// other one is.
    private var nextUnanswered: Int? {
        let count = questions.count
        return (1..<max(count, 1)).lazy.map { (shownIndex + $0) % count }.first { !answered(questions[$0]) }
    }

    private func move(_ step: Int) {
        let count = rows(questions[shownIndex])
        guard count > 0 else { return }
        let from = row.value ?? (step > 0 ? -1 : count)
        let place = min(max(from + step, 0), count - 1)
        row.value = place
        reveal.value = Self.rowID(shownIndex, place)
        PointerGate.keyed()
    }

    private func send() {
        guard ready else { return }
        submit(picks.value.answers(questions))
    }

    // MARK: Keys

    /// The card takes the keys from the composer.
    private func take() {
        guard !holding.value else { return }
        holding.value = true
        composerKeys(false)
    }

    private func start() {
        if monitor.value == nil {
            monitor.value = WindowEvents.monitor([.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        if composerEmpty() { take() }
    }

    private func stop() {
        if let monitor = monitor.value { NSEvent.removeMonitor(monitor) }
        monitor.value = nil
        // Going with the keys, it gives them back.
        if holding.value { composerKeys(true) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        guard event.type == .keyDown else {
            // A click in the card gives it the keys; one anywhere else takes them away.
            guard let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if frame.value.contains(point) {
                take()
            } else if holding.value {
                holding.value = false
            }
            return event
        }
        guard holding.value else { return event }
        // Another text has the keys (the composer, a find field): they're its own.
        if editing.value == nil, let text = window.firstResponder as? NSTextView, !text.isFieldEditor {
            holding.value = false
            return event
        }
        return key(event) ? nil : event
    }

    /// True when the card took the key.
    private func key(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if modifiers == .command, isReturn {
            send()
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        let count = questions.count
        if event.keyCode == 48 {
            let back = modifiers.contains(.shift)
            if count > 1 { go(to: back ? (shownIndex + count - 1) % count : nextUnanswered ?? (shownIndex + 1) % count, keyed: true) }
            return true
        }
        let question = questions[shownIndex]
        if editing.value != nil {
            switch event.keyCode {
            case 53:
                typing = nil
                return true
            case 36, 76:
                typing = nil
                if let next = nextUnanswered { go(to: next, keyed: true) }
                return true
            default:
                return false
            }
        }
        switch event.keyCode {
        case 53:
            holding.value = false
            composerKeys(true)
        case 125: move(1)
        case 126: move(-1)
        case 49:
            if let place = row.value { choose(place, in: question) }
        case 36, 76:
            if let place = row.value {
                let isOther = place >= question.options.count
                // Other opens its field; an option is picked (an any-of's only if none is yet).
                if isOther || !question.multiple || (picks.value.options[question.id] ?? []).isEmpty { choose(place, in: question) }
                if isOther { return true }
            }
            if let next = nextUnanswered { go(to: next, keyed: true) }
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), digit >= 1, digit <= rows(question) else { return false }
            row.value = digit - 1
            PointerGate.keyed()
            choose(digit - 1, in: question)
        }
        return true
    }
}

/// What a question card holds: the options picked and Other's, by question id, and what's typed
/// under Other. A one-of question holds one pick, an option or Other, whichever came last. The
/// words stay while another pick has Other's place (Other picked again brings them back), and go
/// only while Other is picked, or for a question with no options, where they're the only answer.
struct QuestionPicks: Equatable {
    var options: [String: Set<String>] = [:]
    var other: Set<String> = []
    var typed: [String: String] = [:]

    /// An option picked, or an any-of's unpicked; a one-of's takes Other's place.
    mutating func pick(_ label: String, in question: Approval.Question) {
        var labels = options[question.id] ?? []
        if question.multiple {
            if labels.remove(label) == nil { labels.insert(label) }
        } else {
            labels = [label]
            other.remove(question.id)
        }
        options[question.id] = labels
    }

    /// Other picked, true, or unpicked when it was; a one-of's takes the option's place.
    @discardableResult
    mutating func pickOther(in question: Approval.Question) -> Bool {
        if other.remove(question.id) != nil { return false }
        if !question.multiple { options[question.id] = [] }
        other.insert(question.id)
        return true
    }

    /// The typed answer a question sends: nil unless Other is picked or it has no options.
    func text(_ question: Approval.Question) -> String? {
        guard other.contains(question.id) || question.options.isEmpty else { return nil }
        return (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each question's options in their order, then what was typed: the CLIs' answers.
    func answers(_ questions: [Approval.Question]) -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for question in questions {
            let labels = options[question.id] ?? []
            var answer = question.options.map(\.label).filter(labels.contains)
            if let text = text(question), !text.isEmpty { answer.append(text) }
            answers[question.id] = answer
        }
        return answers
    }

    /// Something picked or typed, and no Other left empty.
    func answered(_ question: Approval.Question) -> Bool {
        guard let text = text(question) else { return !(options[question.id] ?? []).isEmpty }
        return !text.isEmpty
    }

    func complete(_ questions: [Approval.Question]) -> Bool { questions.allSatisfy(answered) }
}

/// Other's field: bare in its row at the label's size (the caret shows focus), or in a well.
private struct OtherField: ViewModifier {
    let well: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        if well {
            content.fieldWell(focused: focused)
        } else {
            content
                .textFieldStyle(.plain)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// An option's row: the current row's fill, and a picked one's accent line (its room kept).
    fileprivate func optionRow(current: Bool, on: Bool) -> some View {
        padding(Inset.row)
            .frame(maxWidth: .infinity, minHeight: Size.Question.row, alignment: .topLeading)
            .background(current ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(on ? Theme.accentLine : .clear, lineWidth: Stroke.hairline))
            .contentShape(Rectangle())
    }
}

/// One-of's radio, any-of's checkbox; picked, in the accent.
private struct QuestionGlyph: View {
    let multiple: Bool
    let on: Bool

    var body: some View {
        Group {
            if multiple {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.questionCheckbox)
                        .fill(on ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: Radius.questionCheckbox)
                        .strokeBorder(on ? Theme.accent : Theme.secondary, lineWidth: Stroke.questionGlyph)
                    if on {
                        QuestionTick()
                            .stroke(Theme.background, style: StrokeStyle(lineWidth: Stroke.checkboxTick, lineCap: .round, lineJoin: .round))
                            .frame(width: Size.Question.tick, height: Size.Question.tick)
                    }
                }
            } else {
                ZStack {
                    Circle().strokeBorder(on ? Theme.accent : Theme.secondary, lineWidth: Stroke.questionGlyph)
                    if on {
                        Circle().fill(Theme.accent).frame(width: Size.Question.dot, height: Size.Question.dot)
                    }
                }
            }
        }
        .frame(width: Size.Question.glyph, height: Size.Question.glyph)
        .accessibilityHidden(true)
    }
}

/// A tick, drawn in its box: a picked checkbox's, an answered tab's.
private struct QuestionTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.28))
        return path
    }
}

/// The narrow card's ‹ or ›: a 24pt icon button, filled under the pointer.
private struct QuestionStepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(TextStyle.labelMedium)
                .foregroundStyle(enabled ? Theme.secondary : Theme.tertiary)
                .frame(width: Size.Question.step, height: Size.Question.step)
                .background(enabled && hovered.value ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered.value = $0 }
        .accessibilityLabel(Text(label))
    }
}
