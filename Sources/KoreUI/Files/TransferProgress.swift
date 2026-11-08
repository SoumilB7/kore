import HostClient
import SwiftUI

/// Transfers under way: file copies and moves (`FileCarries`), chat moves and copies, anything
/// whose bytes take a while. Each shows, after half a second, in one quiet bar at the bottom of
/// the explorer it goes into (`TransferBar`): a determinate bar and one line, with Cancel. A
/// finished one says so for 2 s and fades; a failed one stays, with Retry, until it's dismissed.
/// Updates come at most a few times a second from their own meters; nothing runs while idle.
@MainActor @Observable
final class TransferProgress {
    static let shared = TransferProgress()

    enum State: Equatable {
        case running
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

        var fraction: Double? { total > 0 ? min(1, Double(bytes) / Double(total)) : nil }
        var running: Bool { state == .running }

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.title == b.title && a.bytes == b.bytes && a.total == b.total && a.state == b.state && a.shown == b.shown
        }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var cancels: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var retries: [UUID: @MainActor () -> Void] = [:]
    /// A transfer quicker than this never shows.
    @ObservationIgnored var showAfter: Duration = .milliseconds(500)
    /// How long a finished one says so before it fades.
    @ObservationIgnored var doneHold: Duration = .seconds(2)
    /// The clock (tests set their own).
    @ObservationIgnored var now: () -> Date = Date.init

    /// A new transfer: shown if it's still going after `showAfter`.
    @discardableResult
    func begin(
        _ title: String, done: String, place: FilePlace? = nil, window: String? = nil, total: Int64 = 0,
        cancel: (@MainActor () -> Void)? = nil, retry: (@MainActor () -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        items.append(Item(id: id, title: title, doneTitle: done, place: place, window: window, total: total, sampled: now()))
        cancels[id] = cancel
        retries[id] = retry
        Task { [weak self] in
            guard let delay = self?.showAfter else { return }
            try? await Task.sleep(for: delay)
            self?.edit(id) { if $0.running { $0.shown = true } }
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
            item.bytes = bytes
        }
    }

    /// Ended: done says so for `doneHold` then fades (at once when it never showed); a failure
    /// stays until dismissed.
    func finish(_ id: UUID, failure: String? = nil, cancelled: Bool = false) {
        cancels[id] = nil
        guard let item = items.first(where: { $0.id == id }) else { return }
        if cancelled || (failure == nil && !item.shown) { return remove(id) }
        if let failure {
            edit(id) {
                $0.state = .failed(failure)
                $0.shown = true
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

    func cancel(_ id: UUID) { cancels[id]?() }

    func retry(_ id: UUID) {
        let again = retries[id]
        remove(id)
        again?()
    }

    func dismiss(_ id: UUID) { remove(id) }

    /// The ones a window's explorer over `root` (or the window `window`) shows now.
    func shown(under root: FilePlace?, window: String?) -> [Item] {
        items.filter { item in
            item.shown && ((root.map { item.place?.within($0) ?? false } ?? false) || (window != nil && item.window == window))
        }
    }

    private func remove(_ id: UUID) {
        cancels[id] = nil
        retries[id] = nil
        withAnimation(Motion.fade) { items.removeAll { $0.id == id } }
    }

    private func edit(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        if item != items[index] { items[index] = item }
    }

    // MARK: Words

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "about 2 min left": nil while there's no rate to go by.
    static func left(remaining: Int64, rate: Double) -> String? {
        guard rate > 0, remaining > 0 else { return nil }
        let seconds = Double(remaining) / rate
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "about \(max(5, Int((seconds / 5).rounded()) * 5)) s left" }
        if seconds < 3600 { return "about \(max(1, Int((seconds / 60).rounded()))) min left" }
        let hours = seconds / 3600
        return "about \(hours < 10 ? String(format: "%.1f", hours) : String(Int(hours.rounded()))) h left"
    }

    /// One transfer's line: "Copying 3 items to mybox · 1.2 GB of 3.4 GB · about 2 min left";
    /// "Copied to mybox · 3.4 GB"; or why it failed.
    static func line(_ item: Item) -> String {
        switch item.state {
        case .failed(let why): return why
        case .done: return item.doneTitle + (item.total > 0 ? " · " + size(item.total) : "")
        case .running:
            guard item.total > 0 else { return item.title + "…" }
            var parts = [item.title, "\(size(item.bytes)) of \(size(item.total))"]
            if let left = left(remaining: item.total - item.bytes, rate: item.rate) { parts.append(left) }
            return parts.joined(separator: " · ")
        }
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

    @ViewBuilder private func row(_ item: TransferProgress.Item) -> some View {
        let failed: Bool = if case .failed = item.state { true } else { false }
        VStack(alignment: .leading, spacing: Space.xxs) {
            if !failed { bar(item.state == .done ? 1 : item.fraction, failed: false) }
            HStack(spacing: Space.sm) {
                Text(TransferProgress.line(item))
                    .font(Chrome.caption).foregroundStyle(failed ? Theme.text : Theme.secondary).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                if item.running {
                    action("Cancel") { TransferProgress.shared.cancel(item.id) }
                } else if failed {
                    action("Retry") { TransferProgress.shared.retry(item.id) }
                    Button { TransferProgress.shared.dismiss(item.id) } label: { Image(systemName: "xmark").font(Chrome.caption) }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary).help("Dismiss")
                }
            }
        }
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
