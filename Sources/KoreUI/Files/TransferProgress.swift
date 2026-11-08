import AppKit
import HostClient
import SwiftUI

/// Transfers under way: file copies and moves (`FileCarries`), chat moves and copies, anything
/// whose bytes take a while. Each shows, after half a second, in one quiet bar at the bottom of
/// the explorer it goes into (`TransferBar`): a determinate bar and two lines (what goes where;
/// its numbers), with Cancel. A file carry's Cancel offers Pause (its progress kept) or removing
/// the partial copy; a paused one shows Resume. A finished one says so for 2 s and fades; a failed
/// one stays, with Retry, until it's dismissed. Updates come at most a few times a second from
/// their own meters; nothing runs while idle.
@MainActor @Observable
final class TransferProgress {
    static let shared = TransferProgress()

    enum State: Equatable {
        case running
        /// Paused by the user: Resume goes on.
        case paused
        /// Stopped by the link, a quit or a sleep: it goes on by itself once its box is back.
        case waiting
        case done
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        /// "Copying 3 items to mybox"; when it's done, "Copied to mybox".
        var title: String
        var doneTitle: String
        /// Where it goes: its bar shows in the explorer over that folder.
        var place: FilePlace?
        /// Or the window it belongs to (a chat move's), by the workspace's key.
        var window: String?
        var bytes: Int64 = 0
        var total: Int64 = 0
        var state = State.running
        var shown = false
        /// Bytes a second, smoothed.
        var rate: Double = 0
        var sampled: Date
        var sampledBytes: Int64 = 0
        /// The far device it waits on ("mybox"): said when no bytes come for `stallAfter`.
        var peer: String?
        /// When its bytes last rose.
        var moved = Date()
        var stalled = false
        /// Going on from a checkpoint (after a relaunch), until its bytes move.
        var resuming = false
        /// It can pause and resume (a file carry's partial copy is kept).
        var pausable = false
        /// A failure it can go on from (Retry resumes; Cancel removes the partial copy).
        var resumable = false

        var fraction: Double? { total > 0 ? min(1, Double(bytes) / Double(total)) : nil }
        var running: Bool { state == .running }
        /// Still to finish: going, waiting or paused.
        var live: Bool { state == .running || state == .waiting || state == .paused }

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.title == b.title && a.bytes == b.bytes && a.total == b.total && a.state == b.state && a.shown == b.shown
                && a.rate == b.rate && a.stalled == b.stalled && a.resuming == b.resuming && a.resumable == b.resumable
        }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var cancels: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var retries: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var pauses: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var resumes: [UUID: @MainActor () -> Void] = [:]
    /// A transfer quicker than this never shows.
    @ObservationIgnored var showAfter: Duration = .milliseconds(500)
    /// How long a finished one says so before it fades.
    @ObservationIgnored var doneHold: Duration = .seconds(2)
    /// The clock (tests set their own).
    @ObservationIgnored var now: () -> Date = Date.init
    /// No bytes for this long: "waiting for mybox".
    @ObservationIgnored var stallAfter: TimeInterval = 30
    /// How often running ones are checked for that: only while one runs.
    @ObservationIgnored var stallCheck: Duration = .seconds(5)
    @ObservationIgnored private var watching = false

    /// A new transfer: shown if it's still going after `showAfter` (`shown`: at once).
    /// `pause` and `resume`: it keeps its progress when stopped (its Cancel offers Pause).
    @discardableResult
    func begin(
        _ title: String, done: String, id: UUID = UUID(), place: FilePlace? = nil, window: String? = nil, total: Int64 = 0, peer: String? = nil,
        shown: Bool = false, resuming: Bool = false, cancel: (@MainActor () -> Void)? = nil, retry: (@MainActor () -> Void)? = nil,
        pause: (@MainActor () -> Void)? = nil, resume: (@MainActor () -> Void)? = nil
    ) -> UUID {
        let started = now()
        var item = Item(id: id, title: title, doneTitle: done, place: place, window: window, total: total, sampled: started, peer: peer, moved: started)
        item.shown = shown
        item.resuming = resuming
        item.pausable = pause != nil
        items.append(item)
        cancels[id] = cancel
        retries[id] = retry
        pauses[id] = pause
        resumes[id] = resume
        if peer != nil { watchStalls() }
        if !shown {
            Task { [weak self] in
                guard let delay = self?.showAfter else { return }
                try? await Task.sleep(for: delay)
                self?.edit(id) { if $0.live { $0.shown = true } }
            }
        }
        return id
    }

    /// Its bytes now (of `total`, when that's known now).
    func update(_ id: UUID, bytes: Int64, total: Int64? = nil) {
        let time = now()
        edit(id) { item in
            if let total { item.total = total }
            let seconds = time.timeIntervalSince(item.sampled)
            // The rate over the last half second or more, smoothed.
            if seconds >= 0.5 {
                let instant = Double(max(0, bytes - item.sampledBytes)) / seconds
                item.rate = item.rate == 0 ? instant : item.rate * 0.7 + instant * 0.3
                item.sampled = time
                item.sampledBytes = bytes
            }
            if bytes > item.bytes {
                item.moved = time
                item.stalled = false
                // New bytes past where its checkpoint left it: no longer "resuming".
                if item.bytes > 0 { item.resuming = false }
            }
            item.bytes = bytes
        }
    }

    /// Going again (resumed, or back after a wait): its rate measured afresh.
    func running(_ id: UUID) {
        let time = now()
        edit(id) {
            $0.state = .running
            $0.rate = 0
            $0.sampled = time
            $0.sampledBytes = $0.bytes
            $0.moved = time
            $0.stalled = false
        }
        if items.contains(where: { $0.id == id && $0.peer != nil }) { watchStalls() }
    }

    /// Paused by the user: "Paused", with Resume.
    func paused(_ id: UUID) {
        edit(id) {
            $0.state = .paused
            $0.shown = true
            $0.rate = 0
            $0.resuming = false
        }
    }

    /// Stopped by the link, a quit or a sleep: "Paused · waiting for mybox" until it goes on.
    func waiting(_ id: UUID) {
        edit(id) {
            $0.state = .waiting
            $0.shown = true
            $0.rate = 0
        }
    }

    /// Ended: done says so for `doneHold` then fades (at once when it never showed); a failure
    /// stays until dismissed (`resumable`: Retry goes on from it, Cancel removes its partial copy).
    func finish(_ id: UUID, failure: String? = nil, cancelled: Bool = false, resumable: Bool = false) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if !resumable || failure == nil { cancels[id] = nil }
        if cancelled || (failure == nil && !item.shown) { return remove(id) }
        if let failure {
            edit(id) {
                $0.state = .failed(failure)
                $0.shown = true
                $0.resumable = resumable
                $0.resuming = false
            }
            return
        }
        retries[id] = nil
        edit(id) {
            $0.state = .done
            if $0.total > 0 { $0.bytes = $0.total }
        }
        Task { [weak self] in
            guard let hold = self?.doneHold else { return }
            try? await Task.sleep(for: hold)
            self?.remove(id)
        }
    }

    /// Cancel, at once: and with it, the partial copy of one that keeps it.
    func cancel(_ id: UUID) { cancels[id]?() }

    func pause(_ id: UUID) { pauses[id]?() }

    func resume(_ id: UUID) { resumes[id]?() }

    /// Running ones that said nothing for `stallAfter` marked so (their line says what they wait on).
    func checkStalls() {
        let time = now()
        for item in items where item.running && item.peer != nil {
            let stalled = time.timeIntervalSince(item.moved) >= stallAfter
            if stalled != item.stalled { edit(item.id) { $0.stalled = stalled } }
        }
    }

    /// One check every `stallCheck` while any with a peer runs; it ends with the last.
    private func watchStalls() {
        guard !watching else { return }
        watching = true
        Task { [weak self] in
            while let every = self?.stallCheck, self?.items.contains(where: { $0.running && $0.peer != nil }) == true {
                try? await Task.sleep(for: every)
                self?.checkStalls()
            }
            self?.watching = false
        }
    }

    /// Retry: a resumable one goes on (its entry stays); any other starts again.
    func retry(_ id: UUID) {
        let again = retries[id]
        if items.first(where: { $0.id == id })?.resumable != true { remove(id) }
        again?()
    }

    func dismiss(_ id: UUID) { remove(id) }

    /// The ones a window's explorer over `root` (or the window `window`) shows now.
    func shown(under root: FilePlace?, window: String?) -> [Item] {
        items.filter { item in
            item.shown && ((root.map { item.place?.within($0) ?? false } ?? false) || (window != nil && item.window == window))
        }
    }

    func remove(_ id: UUID) {
        cancels[id] = nil
        retries[id] = nil
        pauses[id] = nil
        resumes[id] = nil
        withAnimation(Motion.fade) { items.removeAll { $0.id == id } }
    }

    private func edit(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        if item != items[index] { items[index] = item }
    }

    // MARK: Words

    /// "601 MB", "2.12 GB", "42.5 MB": three figures at most, in Finder's units; nothing yet is
    /// "0 KB" (never "Zero KB").
    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        guard bytes >= 1000 else { return "\(bytes) bytes" }
        return figures(Double(bytes), digits: 3)
    }

    /// "3.1 MB/s", "210 KB/s": two figures (three from 100 up).
    static func speed(_ rate: Double) -> String {
        rate < 1000 ? "\(Int(rate.rounded())) bytes/s" : figures(rate, digits: 2) + "/s"
    }

    /// `value` bytes in the unit that keeps it under 1000, with `digits` significant figures and
    /// no trailing zeros ("2.1 GB", never "2.10 GB").
    private static func figures(_ value: Double, digits: Int) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var amount = value / 1000
        var unit = 0
        while true {
            let decimals = max(0, digits - 1 - (amount >= 1 ? Int(log10(amount).rounded(.down)) : 0))
            let scale = pow(10, Double(decimals))
            let rounded = (amount * scale).rounded() / scale
            if rounded >= 1000, unit < units.count - 1 {
                amount /= 1000
                unit += 1
                continue
            }
            var text = String(format: "%.\(decimals)f", rounded)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text + " " + units[unit]
        }
    }

    /// "2 min left": nil while there's no rate to go by.
    static func left(remaining: Int64, rate: Double) -> String? {
        guard rate > 0, remaining > 0 else { return nil }
        let seconds = Double(remaining) / rate
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "\(max(5, Int((seconds / 5).rounded()) * 5)) s left" }
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) min left" }
        let hours = seconds / 3600
        return "\(hours < 10 ? String(format: "%.1f", hours) : String(Int(hours.rounded()))) h left"
    }

    /// Its first line: what goes where. "Copying NCDEX to mybox"; after a relaunch, until its
    /// bytes move, "Resuming NCDEX to mybox…"; "Copied to mybox · 2.12 GB" when done.
    static func head(_ item: Item) -> String {
        switch item.state {
        case .done: return item.doneTitle + (item.total > 0 ? " · " + size(item.total) : "")
        case .running where item.resuming:
            let rest = item.title.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? item.title
            return "Resuming " + rest + "…"
        case .running where item.total == 0 && !item.stalled: return item.title + "…"
        default: return item.title
        }
    }

    /// Its second line, longest first: each one after drops a part (the speed, then the time
    /// left), so the bar takes the longest that fits and never cuts a number. Empty: one line.
    static func details(_ item: Item) -> [String] {
        let amount = item.total > 0 ? "\(size(item.bytes)) of \(size(item.total))" : nil
        let waitingFor = item.peer.map { "waiting for \($0)" } ?? "waiting"
        switch item.state {
        case .done: return []
        case .failed(let why): return [why]
        case .paused: return [[amount, "Paused"].compactMap { $0 }.joined(separator: " · ")]
        case .waiting: return [[amount, "Paused · " + waitingFor].compactMap { $0 }.joined(separator: " · ")]
        case .running:
            guard let amount else { return item.stalled ? [waitingFor] : [] }
            if item.stalled { return [amount + " · " + waitingFor, amount] }
            guard item.rate > 0, item.bytes > 0, item.bytes < item.total, !item.resuming else { return [amount] }
            let rate = speed(item.rate)
            guard let left = left(remaining: item.total - item.bytes, rate: item.rate) else { return [amount + " · " + rate, amount] }
            return [amount + " · " + rate + " · " + left, amount + " · " + left, amount]
        }
    }

    /// Both lines in one, for its help and for tests: "Copying NCDEX to mybox · 601 MB of 2.12 GB
    /// · 3.1 MB/s · 6 min left".
    static func line(_ item: Item) -> String {
        ([head(item)] + details(item).prefix(1)).joined(separator: " · ")
    }

    /// Several at once: "2 transfers · 38%" (their bytes together).
    static func stacked(_ items: [Item]) -> String {
        let total = items.reduce(Int64(0)) { $0 + $1.total }
        let bytes = items.reduce(Int64(0)) { $0 + min($1.bytes, $1.total) }
        let head = "\(items.count) transfers"
        guard total > 0 else { return head }
        return head + " · \(Int(Double(bytes) / Double(total) * 100))%"
    }

    /// Their bar, together.
    static func fraction(_ items: [Item]) -> Double? {
        let total = items.reduce(Int64(0)) { $0 + $1.total }
        guard total > 0 else { return nil }
        return min(1, Double(items.reduce(Int64(0)) { $0 + min($1.bytes, $1.total) }) / Double(total))
    }
}

/// The bottom bar of an explorer: its transfers' progress. One: a bar and its line, with Cancel
/// (Retry and a close for a failure). Several: one bar and "2 transfers · 38%", each listed while
/// the pointer is over it.
struct TransferBar: View {
    let root: FilePlace?
    var window: String?
    @StateObject private var hovered = Local(false)

    var body: some View {
        let items = TransferProgress.shared.shown(under: root, window: window)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                if items.count == 1 {
                    row(items[0])
                } else {
                    if hovered.value {
                        ForEach(items) { row($0) }
                    } else {
                        bar(TransferProgress.fraction(items), failed: false)
                        Text(TransferProgress.stacked(items)).font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Layout.Explorer.headerInset)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) { Rectangle().fill(Theme.Tree.guide).frame(height: Stroke.hairline) }
            .contentShape(Rectangle())
            .onHover { hovered.value = $0 }
            .animation(Motion.fade, value: hovered.value)
            .transition(.opacity)
        }
    }

    /// Its bar, then two lines: what goes where (cut in the middle when narrow) with its
    /// actions, and its numbers, the longest that fits (`details`) so no number is ever cut. A
    /// failure's words wrap whole, all of it on hover too.
    @ViewBuilder private func row(_ item: TransferProgress.Item) -> some View {
        let failed: Bool = if case .failed = item.state { true } else { false }
        let details = TransferProgress.details(item)
        VStack(alignment: .leading, spacing: Space.xxs) {
            if !failed { bar(item.state == .done ? 1 : item.fraction, failed: false) }
            HStack(spacing: Space.sm) {
                Text(TransferProgress.head(item))
                    .font(Chrome.caption).foregroundStyle(failed ? Theme.text : Theme.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                actions(item, failed: failed)
            }
            if failed, let why = details.first {
                Text(why).font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true).help(why)
            } else if !details.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ForEach(details, id: \.self) { Text($0).lineLimit(1).fixedSize() }
                }
                .font(Chrome.caption).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
        }
        .help(failed ? "" : TransferProgress.line(item))
    }

    /// Cancel while it goes (a carry's: Pause or remove its partial copy, asked in a popup);
    /// Resume when paused; Retry after a failure.
    @ViewBuilder private func actions(_ item: TransferProgress.Item, failed: Bool) -> some View {
        let progress = TransferProgress.shared
        switch item.state {
        case .running, .waiting:
            action("Cancel") {
                guard item.pausable else { return progress.cancel(item.id) }
                Self.ask(item.id, pause: true)
            }
        case .paused:
            action("Resume") { progress.resume(item.id) }
            action("Cancel") { Self.ask(item.id, pause: false) }
        case .failed:
            action("Retry") { progress.retry(item.id) }
            if item.resumable {
                action("Cancel") { Self.ask(item.id, pause: false) }
            } else {
                Button { progress.dismiss(item.id) } label: { Image(systemName: "xmark").font(Chrome.caption) }
                    .buttonStyle(.plain).foregroundStyle(Theme.tertiary).help("Dismiss")
            }
        case .done:
            EmptyView()
        }
    }

    /// A carry's Cancel: Pause (kept) or remove the partial copy, in a Kore popup where the
    /// pointer is.
    static func ask(_ id: UUID, pause: Bool) {
        let progress = TransferProgress.shared
        if let confirm = StorylineSeams.confirm { return confirm("remove partial") ? progress.cancel(id) : progress.pause(id) }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        var entries: [OptionItem] = []
        if pause { entries.append(OptionItem("Pause") { progress.pause(id) }) }
        entries.append(OptionItem("Cancel and remove the partial copy", destructive: true) { progress.cancel(id) })
        OptionsMenu.shared.show(entries, at: window.mouseLocationOutsideOfEventStream, in: window, source: "transfer")
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(.plain).font(Chrome.caption).foregroundStyle(Theme.tertiary)
    }

    /// Determinate when the total is known, else a quiet sweep.
    @ViewBuilder private func bar(_ fraction: Double?, failed: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Tree.guide)
                Capsule().fill(Theme.accent.opacity(0.8))
                    .frame(width: geometry.size.width * (fraction ?? 0.15))
                    .animation(.linear(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 3)
    }
}
