import AppKit
import KoreCore
import Observation
import SwiftUI

/// The usage popup's state in one chat: open or not, and what it shows. Each open reads once
/// through the chat's CLI; nothing runs while it's closed. The last reading of each provider is
/// kept (in memory) and shown at once on the next open, stamped "as of", while the new one loads.
@MainActor @Observable
final class UsageState {
    enum Status: Equatable {
        case loading
        case fresh
        /// The read failed: the last limits show dimmed, under the reason (the CLI's words, if any).
        case unavailable(String?)
    }

    private(set) var isOpen = false
    private(set) var status = Status.loading
    /// What shows: the reading just made, or the last one while it loads (or after it failed).
    private(set) var reading: PlanReading?
    /// When `reading`'s limits were read.
    private(set) var readAt: Date?
    /// Each open's own number: a read that lands after a close, or after the next open, is
    /// only kept for next time.
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var patienceTimer: Task<Void, Never>?

    /// Each provider's last reading, and when it was made.
    private static var kept: [String: (reading: PlanReading, at: Date)] = [:]
    /// A read the CLI never answers stops showing a spinner after this.
    private static let patience: Duration = .seconds(35)

    func open(provider: String, read: @escaping @MainActor () async throws -> PlanReading) {
        serial += 1
        let open = serial
        isOpen = true
        status = .loading
        let last = Self.kept[provider]
        (reading, readAt) = (last?.reading, last?.at)
        Task { [weak self] in
            let outcome: Result<PlanReading, any Error>
            do { outcome = .success(try await read()) } catch { outcome = .failure(error) }
            if case .success(let new) = outcome, new.limits != nil || new.account.access != .plan {
                Self.kept[provider] = (new, Date())
            }
            guard let self, self.serial == open else { return }
            self.land(outcome, last: last)
        }
        patienceTimer?.cancel()
        patienceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard let self, !Task.isCancelled, self.serial == open, self.status == .loading else { return }
            self.status = .unavailable(nil)
        }
    }

    func close() {
        guard isOpen else { return }
        serial += 1
        isOpen = false
        patienceTimer?.cancel()
    }

    private func land(_ outcome: Result<PlanReading, any Error>, last: (reading: PlanReading, at: Date)?) {
        switch outcome {
        case .success(let new) where new.limits != nil || new.account.access != .plan:
            (reading, readAt, status) = (new, Date(), .fresh)
        case .success(let new):
            // The account as it is now, over the last limits read.
            reading = PlanReading(account: new.account, limits: last?.reading.limits)
            status = .unavailable(new.reason)
        case .failure(let error):
            status = .unavailable(PlanReading.reason(of: error))
        }
    }

    /// The popup's bars, each as one line, for a storyline's checks ("Weekly limit · 6% · Resets in 4d").
    var lines: [String] {
        let now = Date()
        return (reading?.limits?.bars ?? []).map { bar in
            [bar.title, UsageText.percent(bar.used), UsageText.resets(bar.resetsAt, now: now)].joined(separator: " · ")
        }
    }
}

extension PlanReading {
    /// An error as the reason line's words: a readable message, never raw JSON.
    static func reason(of error: any Error) -> String? {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        guard let line = message.split(whereSeparator: \.isNewline).first.map(String.init),
            !line.hasPrefix("{"), !line.hasPrefix("[")
        else { return nil }
        return line
    }
}

/// The popup's wording and layout arithmetic.
enum UsageText {
    /// Whole percents, rounded down: 29.9% used is "29%".
    static func percent(_ used: Double) -> String { "\(Int(max(used, 0).rounded(.down)))%" }

    /// How much of the bar fills.
    static func fraction(_ used: Double) -> Double { min(max(used / 100, 0), 1) }

    /// "Resets in 3h", "Resets in 12m", "Resets in 6d", "Resets soon"; nothing without a time.
    static func resets(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "Resets soon" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "Resets in \(minutes)m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "Resets in \(hours)h" }
        return "Resets in \(Int((seconds / 86400).rounded()))d"
    }

    /// "as of 4 min ago"; nil for a reading under a minute old.
    static func stamp(_ readAt: Date?, now: Date) -> String? {
        guard let readAt else { return nil }
        let minutes = Int(now.timeIntervalSince(readAt) / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "as of \(minutes) min ago" }
        if minutes < 24 * 60 { return "as of \(minutes / 60) h ago" }
        return "as of \(minutes / (24 * 60)) d ago"
    }

    /// clamp(1, ⌊(W − 24 + 16) / (180 + 16)⌋, bars) for a popup `width` wide: its padding off,
    /// then as many columns of at least `usageColumnMin` as fit with their gaps.
    static func columns(width: CGFloat, bars: Int) -> Int {
        let inner = width - Inset.block.leading - Inset.block.trailing
        let fit = Int(((inner + Space.xxxl) / (Size.usageColumnMin + Space.xxxl)).rounded(.down))
        return min(max(fit, 1), max(bars, 1))
    }

    /// "you@example.com · Acme Labs".
    static func who(_ account: PlanAccount) -> String {
        [account.email, account.organization].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Credits 47,161.94 · 2 full resets available".
    static func extras(_ extras: [PlanExtra]) -> String {
        extras.map { [$0.key, $0.value].compactMap { $0 }.joined(separator: " ") }.joined(separator: " · ")
    }

    /// The same line, its keys in the secondary colour.
    static func extrasText(_ extras: [PlanExtra]) -> AttributedString {
        var line = AttributedString()
        for (index, extra) in extras.enumerated() {
            if index > 0 { line += AttributedString(" · ") }
            if let key = extra.key {
                var part = AttributedString(key + " ")
                part.foregroundColor = Theme.secondary
                line += part
            }
            line += AttributedString(extra.value)
        }
        return line
    }
}

/// The / menu's Usage, in the menu's place over the chat (variant B of the design): the plan,
/// who's signed in and the freshness on one line with the link to manage usage, then a bar per
/// limit in columns that fit the width, then one caption of extras. Opaque, no shadow. Esc
/// closes it and goes no further; a click outside or typing closes it and goes on, so the
/// composer keeps focus throughout (the context card's monitor pattern).
struct UsagePopup: View {
    let state: UsageState
    let wording: UsageWording
    /// The most it may be tall: the room above the composer.
    let room: CGFloat
    @StateObject private var width: Local<CGFloat>
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    init(state: UsageState, wording: UsageWording, width: CGFloat, room: CGFloat) {
        self.state = state
        self.wording = wording
        self.room = room
        // The composer's width from the first pass, so the grid opens at its final size.
        _width = StateObject(wrappedValue: Local(width))
    }

    var body: some View {
        ScrollView {
            content
                .padding(Inset.block)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: room)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame.value = $0
            width.value = $0.width
        }
        .background(WindowReader { window.value = $0 })
        .storyID(StoryID.Composer.usage)
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    @ViewBuilder private var content: some View {
        let account = state.reading?.account
        switch account?.access {
        case .signedOut:
            Text(wording.signedOut).font(TextStyle.label).foregroundStyle(Theme.text)
        case .perToken(let line):
            VStack(alignment: .leading, spacing: Space.md) {
                header(account)
                Text(line).font(TextStyle.caption).foregroundStyle(Theme.secondary)
            }
        case .plan, nil:
            VStack(alignment: .leading, spacing: 0) {
                // Before any reading the header waits for one; with none ever read, only the reason shows.
                if account != nil || state.status == .loading { header(account) }
                limits
            }
        }
    }

    // MARK: Header

    private func header(_ account: PlanAccount?) -> some View {
        let who = account.map(UsageText.who) ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(account?.plan ?? " ").font(TextStyle.title).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
            Text(who)
                .font(TextStyle.label)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(who)
            Spacer(minLength: 0)
            freshness
            if let url = account?.manage { link(url) }
        }
    }

    /// The spinner while the first reading loads; "as of …" while an older one shows.
    @ViewBuilder private var freshness: some View {
        if state.status == .loading, state.reading?.limits == nil {
            SpinningArc().frame(width: Size.spinner, height: Size.spinner)
        } else if state.status != .fresh, let stamp = UsageText.stamp(state.readAt, now: Date()) {
            Text(stamp).font(TextStyle.caption).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
        }
    }

    private func link(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
            state.close()
        } label: {
            HStack(spacing: Space.xs) {
                if width.value >= Size.usageLinkFull { Text("Manage usage") }
                Image(systemName: "arrow.up.right").font(Glyph.chevron)
            }
            .font(TextStyle.label)
            .foregroundStyle(Theme.accent)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Manage usage on \(url.host() ?? url.absoluteString)")
        .storyID(StoryID.Composer.usage.part(.open))
    }

    // MARK: Limits

    @ViewBuilder private var limits: some View {
        let unavailable: String?? = if case .unavailable(let detail) = state.status { .some(detail) } else { nil }
        if let detail = unavailable {
            Text(wording.failed(detail))
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, state.reading == nil ? 0 : Space.sm)
        }
        let bars = state.reading?.limits?.bars
        // Loading with nothing kept: the usual rows, empty.
        let rows = bars.map { $0.map(Optional.some) } ?? (state.status == .loading ? wording.rows.map { _ in nil } : [])
        if !rows.isEmpty {
            let columns = UsageText.columns(width: width.value, bars: rows.count)
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(Array(stride(from: 0, to: rows.count, by: columns)), id: \.self) { start in
                    HStack(alignment: .top, spacing: Space.xxxl) {
                        ForEach(start..<start + columns, id: \.self) { index in
                            if index < rows.count {
                                LimitCell(limit: rows[index], placeholder: wording.rows.indices.contains(index) ? wording.rows[index] : "")
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)  // lint:allow an empty slot, not a size
                            }
                        }
                    }
                }
            }
            .padding(.top, Space.lg)
            .opacity(unavailable == nil ? 1 : Theme.dimmed)
        }
        let extras = state.reading?.limits?.extras ?? []
        if !extras.isEmpty {
            Text(UsageText.extrasText(extras))
                .font(TextStyle.caption)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(UsageText.extras(extras))
                .padding(.top, Space.lg)
                .opacity(unavailable == nil ? 1 : Theme.dimmed)
        }
    }

    // MARK: Dismissal

    /// Esc and Return close it and go no further (Return never sends from under it); any other
    /// key closes it and goes on to the field; a click outside it closes it and goes on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        if event.type == .keyDown {
            state.close()
            // Esc, Return, keypad Enter.
            return [53, 36, 76].contains(event.keyCode) ? nil : event
        }
        guard let content = window.contentView else { return event }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point) { state.close() }
        return event
    }
}

/// One limit: its title and percent, the bar, and when it resets. Nil while loading: the title
/// it usually has, an empty track and "—".
private struct LimitCell: View {
    let limit: PlanLimit?
    let placeholder: String
    /// The bar's fill as drawn: it moves to a new value on its own, so the grid's reflow when
    /// more bars arrive isn't animated with it.
    @StateObject private var shown: Local<Double>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(limit: PlanLimit?, placeholder: String) {
        self.limit = limit
        self.placeholder = placeholder
        _shown = StateObject(wrappedValue: Local(limit.map { UsageText.fraction($0.used) } ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
                Text(limit?.title ?? placeholder).font(TextStyle.labelMedium).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(limit.map { UsageText.percent($0.used) } ?? "—").font(TextStyle.label.monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            UsageBar(fraction: shown.value)
                .padding(.top, Space.xs)
                .padding(.bottom, Size.usageBarBelow)
            Text(limit.map { UsageText.resets($0.resetsAt, now: Date()) } ?? " ")
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .storyID(limit.map { StoryID.Composer.usageLimit($0.title) })
        .onChange(of: limit.map { UsageText.fraction($0.used) } ?? 0) { _, now in
            if reduceMotion { shown.value = now } else { withAnimation(Motion.contextArc) { shown.value = now } }
        }
    }
}

/// The context card's track at its intent height: the used part from the left, coloured by how
/// near the limit it is, at least as wide as it is tall so a sliver still shows. Drawn in one
/// canvas; animatable, so a new value moves it as the ring moves.
private struct UsageBar: View, @preconcurrency Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        let fraction = fraction
        Canvas { canvas, size in
            let line = size.height
            func bar(_ width: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: line), cornerRadius: line / 2)
            }
            canvas.fill(bar(size.width), with: .color(Theme.contextTrack))
            if fraction > 0 { canvas.fill(bar(max(size.width * fraction, line)), with: .color(Theme.usageFill(fraction))) }
        }
        .frame(height: Size.contextTrack.intent)
    }
}
