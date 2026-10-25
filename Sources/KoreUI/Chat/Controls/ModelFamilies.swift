import AppKit
import Foundation

/// One row of the model picker (model-picker.html, "How rows group"): a family is a model's
/// display name with its version number taken out ("Lyra 4.7" → Lyra · 4.7, "Atlas-6 Luna" →
/// Atlas Luna · 6). Families come in the order of their first model in the CLI's list, their
/// versions newest first; a name with no number is a family of one. Nothing is hard-coded, so a
/// new family, or another CLI's list, needs no change.
struct ModelFamily: Equatable {
    let name: String
    /// Newest first. A family without versions holds its one model, `version` nil.
    let members: [Member]

    struct Member: Equatable {
        let model: ModelOption
        let version: String?
    }

    /// The model a click on the family's name picks.
    var newest: ModelOption { members[0].model }

    /// A family of one, with no number: its name is its only chip.
    var versionless: Bool { members.count == 1 && members[0].version == nil }

    static func group(_ models: [ModelOption]) -> [ModelFamily] {
        var order: [String] = []
        var members: [String: [Member]] = [:]
        for model in models {
            let (family, version) = split(model.name)
            // Two versionless models can't share a row: each is its own family.
            let key = version == nil ? "\u{0}" + model.id : family
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(Member(model: model, version: version))
        }
        return order.map { key in
            let list = members[key] ?? []
            let sorted = list.enumerated().sorted { a, b in
                let (x, y) = (a.element.version ?? "", b.element.version ?? "")
                if x != y, newer(x, y) || newer(y, x) { return newer(x, y) }
                return a.offset < b.offset
            }.map(\.element)
            let name = key.hasPrefix("\u{0}") ? (list.first?.model.name ?? "") : key
            return ModelFamily(name: name, members: sorted)
        }
    }

    /// A display name's family and version: the first word that is a number ("4.7", "6"), with
    /// the space or hyphen before it; the rest, trimmed, is the family. No number: the name, nil.
    static func split(_ name: String) -> (family: String, version: String?) {
        var pieces: [(separator: Substring, word: Substring)] = []
        var index = name.startIndex
        while index < name.endIndex {
            let wordStart = name[index...].firstIndex { !isSeparator($0) } ?? name.endIndex
            let wordEnd = name[wordStart...].firstIndex(where: isSeparator) ?? name.endIndex
            pieces.append((name[index..<wordStart], name[wordStart..<wordEnd]))
            index = wordEnd
        }
        guard let at = pieces.firstIndex(where: { isVersion($0.word) }) else { return (name, nil) }
        let version = String(pieces[at].word)
        pieces.remove(at: at)
        // Leading, its next word's separator goes too ("6 Luna" → "Luna").
        if at == 0, !pieces.isEmpty { pieces[0].separator = "" }
        let family = pieces.map { String($0.separator) + $0.word }.joined().trimmingCharacters(in: .whitespaces)
        return family.isEmpty ? (name, nil) : (family, version)
    }

    /// Whether version `a` is newer than `b`, number by number ("5.1" > "5" > "4.10" > "4.9").
    static func newer(_ a: String, _ b: String) -> Bool {
        let (x, y) = (numbers(a), numbers(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func isSeparator(_ c: Character) -> Bool { c == " " || c == "-" || c == "_" }

    private static func isVersion(_ word: Substring) -> Bool {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// How many of a row's chips show before a "…" chip takes the rest: all of them when they
    /// fit `room`; else as many as fit beside the "…".
    static func fold(_ widths: [CGFloat], more: CGFloat, gap: CGFloat, room: CGFloat) -> Int {
        let all = widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
        if all <= room + 0.5 { return widths.count }
        var used = more
        var shown = 0
        for width in widths {
            guard used + width + gap <= room + 0.5 else { break }
            used += width + gap
            shown += 1
        }
        return shown
    }

    /// A chip's width for its label: the label in the chip's type (medium, the wider of its
    /// two weights, so a chip turning current doesn't fold its row) and its padding.
    @MainActor static func chipWidth(_ label: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12 * Zoom.shared.scale, weight: .medium)
        return ((label as NSString).size(withAttributes: [.font: font]).width).rounded(.up) + 2 * Space.md
    }
}

/// The effort levels a CLI offers, as the picker's slider shows them: every level any of its
/// models has, lowest first, so the slider keeps its length from model to model.
enum EffortScale {
    /// The levels both CLIs name, lowest first.
    private static let known = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func levels(_ models: [ModelOption]) -> [String] {
        var scale: [String] = []
        for model in models {
            for (i, level) in model.efforts.enumerated() where !scale.contains(level) {
                // After the level the model lists before it, else first.
                let after = i > 0 ? scale.firstIndex(of: model.efforts[i - 1]).map { $0 + 1 } : nil
                scale.insert(level, at: after ?? 0)
            }
        }
        guard scale.allSatisfy(known.contains) else { return scale }
        return scale.sorted { (known.firstIndex(of: $0) ?? 0) < (known.firstIndex(of: $1) ?? 0) }
    }

    /// The level a model takes when it's picked: the current one when it offers it, else its
    /// nearest level below, else its lowest. Nil with no current level or none offered.
    static func fallback(_ current: String?, offered: [String], scale: [String]) -> String? {
        guard let current, !offered.isEmpty else { return nil }
        if offered.contains(current) { return current }
        let rank = { (level: String) in scale.firstIndex(of: level) ?? Int.max }
        let sorted = offered.sorted { rank($0) < rank($1) }
        guard let at = scale.firstIndex(of: current) else { return sorted[0] }
        return sorted.last { rank($0) < at } ?? sorted[0]
    }

    /// The next offered level up (`by` 1) or down (-1) from `current`, skipping those the model
    /// lacks; the current one at an end. With no current level, the lowest.
    static func step(_ current: String?, by delta: Int, offered: [String], scale: [String]) -> String? {
        let indices = scale.indices.filter { offered.contains(scale[$0]) }
        guard !indices.isEmpty else { return nil }
        guard let current, let at = scale.firstIndex(of: current) else { return scale[indices[0]] }
        let next = delta > 0 ? indices.first { $0 > at } : indices.last { $0 < at }
        return next.map { scale[$0] } ?? (offered.contains(current) ? current : scale[indices[0]])
    }

    /// The offered level nearest a stop: the stop's own, else the closest, the lower on a tie.
    static func nearest(_ stop: Int, offered: [String], scale: [String]) -> String? {
        let indices = scale.indices.filter { offered.contains(scale[$0]) }
        return indices.min { abs($0 - stop) < abs($1 - stop) || (abs($0 - stop) == abs($1 - stop) && $0 < $1) }.map { scale[$0] }
    }

    /// "xhigh" → "Extra high", "low" → "Low".
    static func name(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
    }
}

/// Where the model picker's keys are: a chip, by its family's row and its column, or the
/// effort slider.
enum PickerSpot: Hashable {
    case chip(row: Int, column: Int)
    case effort
    /// The fast mode switch, under the slider.
    case fast
    /// A row of the mode popup.
    case row(Int)
}

/// The model picker's arrow keys over its rows: ←→ through a row's versions, ↑↓ between
/// families in the same column (or the row's last chip), ↓ past the last family to the effort
/// slider and the fast mode switch, where they show, ↑ back.
struct ModelPickerGrid {
    /// Each family's chip count, top to bottom.
    let rows: [Int]
    var effort = true
    var fast = false

    enum Move { case left, right, up, down }

    func move(_ spot: PickerSpot, _ move: Move) -> PickerSpot {
        guard !rows.isEmpty else { return below(spot) }
        switch (spot, move) {
        case (.chip(let row, let column), .left):
            return .chip(row: row, column: max(column - 1, 0))
        case (.chip(let row, let column), .right):
            return .chip(row: row, column: min(column + 1, max(count(row) - 1, 0)))
        case (.chip(let row, let column), .up):
            let up = max(row - 1, 0)
            return .chip(row: up, column: min(column, max(count(up) - 1, 0)))
        case (.chip(let row, let column), .down):
            guard row + 1 < rows.count else { return below(spot) }
            return .chip(row: row + 1, column: min(column, max(count(row + 1) - 1, 0)))
        case (.effort, .up):
            return .chip(row: rows.count - 1, column: 0)
        case (.effort, .down):
            return fast ? .fast : .effort
        case (.effort, _):
            return .effort
        case (.fast, .up):
            return effort ? .effort : .chip(row: rows.count - 1, column: 0)
        case (.fast, _):
            return .fast
        case (.row, _):
            return .chip(row: 0, column: 0)
        }
    }

    /// Past the last family: the slider, else the switch, else nowhere further.
    private func below(_ spot: PickerSpot) -> PickerSpot { effort ? .effort : fast ? .fast : spot }

    private func count(_ row: Int) -> Int { row >= 0 && row < rows.count ? rows[row] : 0 }
}
