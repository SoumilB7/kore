import AppKit
import KoreUI
import Vision

// The live check's eyes (scripts/live-check.sh): what a person sees, read from the window's own
// frames, never the screen. A frame is the window's frame view drawn into a bitmap, as
// `snapshot` draws it; popups are views in the window, so they're in it. Every check here fails
// with one short line that ends with the frame that shows it, "(shots/<file>.png)".

extension Tag {
    /// The live check's tour: one storyline per area. (`live` is taken: it means a live model.)
    package static let liveCheck: Tag = "livecheck"
}

/// Vision's answer, handed from its queue.
final class OCRBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]?
    func set(_ value: [String]) { lock.lock(); lines = value; lock.unlock() }
    func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return lines }
}

@MainActor
enum LiveEyes {
    /// How long a click may take to settle (`KORE_LIVE_SETTLE_MS`, 800 by default).
    nonisolated static let settleBudget = Int(ProcessInfo.processInfo.environment["KORE_LIVE_SETTLE_MS"] ?? "") ?? 800

    static func frame(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        hideScrollers(in: view, rep)
        return rep
    }

    /// Overlay scrollers flash and fade on their own: each one's strip is filled from the pixels
    /// just left of it, so no comparison sees one (and the saved frame reads as without it).
    private static func hideScrollers(in root: NSView, _ rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData else { return }
        let scale = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
        let (bpp, row) = (rep.bitsPerPixel / 8, rep.bytesPerRow)
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard view is NSScroller, !view.isHiddenOrHasHiddenAncestor else { continue }
            let r = view.convert(view.bounds, to: nil)
            let x0 = max(1, Int(r.minX * scale)), x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
            let y0 = max(0, Int((rep.size.height - r.maxY) * scale)), y1 = min(rep.pixelsHigh, Int(((rep.size.height - r.minY) * scale).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                let source = y * row + (x0 - 1) * bpp
                for x in x0..<x1 {
                    let o = y * row + x * bpp
                    for c in 0..<bpp { data[o + c] = data[source + c] }
                }
            }
        }
    }

    /// Writes the frame as `shots/<name>.png` in the run's folder; the relative path.
    @discardableResult
    static func save(_ rep: NSBitmapImageRep, _ name: String, _ story: StoryContext) -> String {
        let file = "shots/\(name).png"
        let url = story.outputs.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        return file
    }

    /// The share of pixels in `rect` (window coordinates; nil: the whole frame) that differ
    /// between two frames by more than a little in any colour.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect? = nil) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
            a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData
        else { return 1 }
        let (w, h) = (a.pixelsWide, a.pixelsHigh)
        let scale = CGFloat(w) / max(a.size.width, 1)
        var (x0, x1, y0, y1) = (0, w, 0, h)
        if let r = rect {
            x0 = max(0, Int(r.minX * scale)); x1 = min(w, Int(r.maxX * scale))
            y0 = max(0, Int((a.size.height - r.maxY) * scale)); y1 = min(h, Int((a.size.height - r.minY) * scale))
        }
        guard x1 > x0, y1 > y0 else { return 0 }
        let (bpp, row) = (a.bitsPerPixel / 8, a.bytesPerRow)
        let channels = min(bpp, 3)
        var differ = 0
        for y in y0..<y1 {
            let base = y * row
            for x in x0..<x1 {
                let o = base + x * bpp
                for c in 0..<channels where abs(Int(pa[o + c]) - Int(pb[o + c])) > 12 {
                    differ += 1
                    break
                }
            }
        }
        return Double(differ) / Double((x1 - x0) * (y1 - y0))
    }

    /// The same bytes: the quick answer for frames that haven't changed.
    static func identical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
            a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData
        else { return false }
        return memcmp(pa, pb, a.bytesPerRow * a.pixelsHigh) == 0
    }

    /// Where two frames differ (window points, y up), as one box; nil when they don't.
    static func changed(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGRect? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
            a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData
        else { return nil }
        let (w, h) = (a.pixelsWide, a.pixelsHigh)
        let (bpp, row) = (a.bitsPerPixel / 8, a.bytesPerRow)
        var (x0, x1, y0, y1) = (w, -1, h, -1)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * row + x * bpp
                for c in 0..<min(bpp, 3) where abs(Int(pa[o + c]) - Int(pb[o + c])) > 12 {
                    (x0, x1, y0, y1) = (min(x0, x), max(x1, x), min(y0, y), max(y1, y))
                    break
                }
            }
        }
        guard x1 >= 0 else { return nil }
        let scale = CGFloat(w) / max(a.size.width, 1)
        return CGRect(x: CGFloat(x0) / scale, y: a.size.height - CGFloat(y1 + 1) / scale, width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }

    /// The lines of text in a frame (Vision, in process, off the main thread); nil when it takes
    /// over `seconds` (a busy Mac): the text isn't judged then.
    static func texts(_ rep: NSBitmapImageRep, _ story: StoryContext, within seconds: Double = 5) async -> [String]? {
        guard let image = rep.cgImage else { return [] }
        let box = OCRBox()
        nonisolated(unsafe) let cg = image
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            box.set((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }
        return try? await story.wait("the frame's text", timeout: .seconds(seconds)) { box.get() }
    }

    /// Work words left on screen once it settled: "Installing…" after the install.
    static let stale = ["Installing", "Loading", "Connecting", "Updating", "Downloading", "Starting", "Building", "Signing in", "Switching"]
    static func isStale(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("…") || t.hasSuffix("...") else { return false }
        return stale.contains { t.localizedCaseInsensitiveContains($0) }
    }

    /// Labels whose cut-off start reads as a word of its own: "This Ma".
    static let labels = ["This Mac", "Full access", "Add a box", "Use SSH", "Devices", "History", "Explorer"]
    static func isClipped(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return labels.contains { t.count >= 4 && t.count < $0.count && $0.hasPrefix(t) && $0.dropFirst(t.count).first != " " }
    }

    /// Lets `ms` pass, the run loop turning (no Task.sleep: it can resume late on a busy host).
    static func pass(_ story: StoryContext, ms: Int) async throws {
        let until = ContinuousClock.now + .milliseconds(ms)
        try await story.until("\(ms) ms to pass", timeout: .seconds(Double(ms) / 1000 + 5)) { ContinuousClock.now >= until }
    }

    /// Frames 120 ms apart until two match: the window settled. nil: still changing after `ms`.
    static func settle(_ window: NSWindow, _ story: StoryContext, ms: Int = 2000) async throws -> NSBitmapImageRep? {
        let start = ContinuousClock.now
        var previous = frame(window)
        while ContinuousClock.now - start < .milliseconds(ms) {
            try await pass(story, ms: 120)
            let next = frame(window)
            if let a = previous, let b = next, difference(a, b) == 0 { return b }
            previous = next
        }
        return nil
    }

    /// The registered frames in `window` whose ids start with `prefix`.
    static func frames(_ prefix: String, in window: NSWindow) -> [(String, CGRect)] {
        StoryRegistry.ids.filter { $0.hasPrefix(prefix) }.flatMap { id in
            StoryRegistry.entries(id, in: window).compactMap { entry in entry.frame.map { (id, $0) } }
        }
    }
}

/// Looks at the area once it settles: `frames` frames 300 ms apart must match (no flicker, no
/// layout loop), and the last one must hold no work word left over and no clipped label.
struct Look: Step {
    let name: String
    var frames = 1
    /// Where the frames are compared (window coordinates); nil: the whole window.
    var region: (@MainActor (StoryContext) -> CGRect?)? = nil
    /// The window looked at; nil: the folder's.
    var window: (@MainActor (StoryContext) -> NSWindow?)? = nil
    /// Run every 20 ms while it looks: what would set a layout loop going (tailnet events).
    var during: (@MainActor (StoryContext) -> Void)? = nil
    var label: String { "Look at \(name)" + (frames > 1 ? " (\(frames) frames)" : "") + (during == nil ? "" : ", events every 20 ms") }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        try await story.idle()
        guard let win = window?(story) ?? story.window else { throw StoryFailure.modelMissing("the window") }
        let base = "\(story.name)-\(name)"
        var ticker: Timer?
        if let during {
            nonisolated(unsafe) let hook = during
            nonisolated(unsafe) let context = story
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { hook(context) } }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        defer { ticker?.invalidate() }
        // Settled first: a change that ends (a row drawn late, a fold animating) isn't flicker;
        // one that never ends is.
        guard let first = try await LiveEyes.settle(win, story) else {
            let file = LiveEyes.frame(win).map { LiveEyes.save($0, "\(base)-unsettled", story) } ?? ""
            throw StoryFailure.other("flicker: never settles in 2 s (\(file))")
        }
        var shots = [first]
        for _ in 1..<max(frames, 1) {
            try await LiveEyes.pass(story, ms: 300)
            guard let frame = LiveEyes.frame(win) else { throw StoryFailure.other("no frame of the window") }
            shots.append(frame)
        }
        let last = LiveEyes.save(shots[shots.count - 1], base, story)
        let rect = region?(story)
        // Flicker: still changing at the last frame, or back to an earlier frame after a change
        // (A→B→A). A change that goes one way and stays (a scroller fading) isn't.
        let limit = 0.001
        let n = shots.count
        if n > 1 {
            let end = LiveEyes.difference(shots[n - 2], shots[n - 1], in: rect)
            var back: (Int, Double)?
            for i in 0..<(n - 2) where LiveEyes.difference(shots[i], shots[i + 1], in: rect) > limit {
                let d = LiveEyes.difference(shots[i], shots[n - 1], in: rect)
                if d <= limit { back = (i, LiveEyes.difference(shots[i], shots[i + 1], in: rect)) }
            }
            if end > limit || back != nil {
                for (i, shot) in shots.enumerated() { LiveEyes.save(shot, "\(base)-\(i + 1)", story) }
                let d = end > limit ? end : back!.1
                let at = end > limit ? n : back!.0 + 2
                throw StoryFailure.other("flicker: frame \(at) of \(n) differs \(String(format: "%.1f", d * 100))% (shots/\(base)-\(at).png)")
            }
        }
        guard let lines = await LiveEyes.texts(shots[shots.count - 1], story) else {
            story.note("\(name) text: not read in 5 s")
            return
        }
        story.note("\(name) text: \(lines.joined(separator: " | "))")
        if let stale = lines.first(where: LiveEyes.isStale) { throw StoryFailure.other("stale “\(stale)” (\(last))") }
        if let cut = lines.first(where: LiveEyes.isClipped) { throw StoryFailure.other("clipped “\(cut)” (\(last))") }
    }
}

/// The element measures the same at two window heights (the layout follows its content, not the
/// window): the message rail on a chat that doesn't change.
struct SameAtHeights: Step {
    let what: String
    let id: StoryID
    var heights: (CGFloat, CGFloat) = (700, 1000)
    var label: String { "\(what) the same at \(Int(heights.0)) and \(Int(heights.1)) pt" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let width = window.contentView?.bounds.width else { throw StoryFailure.modelMissing("the window") }
        var sizes: [CGSize] = []
        var file = ""
        for (n, h) in [heights.0, heights.1].enumerated() {
            window.setContentSize(CGSize(width: width, height: h))
            try await story.idle()
            _ = try await LiveEyes.settle(window, story, ms: 1000)
            guard let frame = StoryElement(id, in: window)?.frame else { throw StoryFailure.elementNotFound(id.raw, nearby: []) }
            sizes.append(frame.size)
            if let shot = LiveEyes.frame(window) { file = LiveEyes.save(shot, "\(story.name)-height-\(n + 1)", story) }
        }
        window.setContentSize(story.windowSize)
        try await story.idle()
        story.note("\(what): \(sizes)")
        if abs(sizes[0].height - sizes[1].height) > 2 || abs(sizes[0].width - sizes[1].width) > 2 {
            throw StoryFailure.other("\(what) follows the window: \(Int(sizes[0].height))→\(Int(sizes[1].height)) pt (\(file))")
        }
    }
}

/// No element under `over` covers one under any of `under` (ids by prefix): a rail over text.
struct NoOverlap: Step {
    let what: String
    let over: String
    let under: [String]
    var label: String { "Nothing under \(what)" }

    func run(_ story: StoryContext) async throws {
        try await story.idle()
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        let tops = LiveEyes.frames(over, in: window)
        let rest = under.flatMap { LiveEyes.frames($0, in: window) }
        for (a, fa) in tops {
            for (b, fb) in rest where b != a {
                let i = fa.intersection(fb)
                guard !i.isNull, i.width > 1, i.height > 1 else { continue }
                let file = LiveEyes.frame(window).map { LiveEyes.save($0, "\(story.name)-overlap", story) } ?? ""
                throw StoryFailure.other("\(what) over \(b.prefix(while: { $0 != "[" })) (\(file))")
            }
        }
    }
}

/// Each element is whole inside its window: nothing cut off at an edge at this size.
struct InsideWindow: Step {
    let ids: [StoryID]
    var window: (@MainActor (StoryContext) -> NSWindow?)? = nil
    var label: String { "Whole in the window: \(ids.map(\.raw).joined(separator: ", "))" }

    func run(_ story: StoryContext) async throws {
        try await story.idle()
        guard let win = window?(story) ?? story.window, let bounds = win.contentView?.bounds else { throw StoryFailure.modelMissing("the window") }
        for id in ids {
            guard let frame = StoryRegistry.entry(id.raw, in: win)?.frame else { continue }
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                let file = LiveEyes.frame(win).map { LiveEyes.save($0, "\(story.name)-clipped", story) } ?? ""
                throw StoryFailure.other("\(id.raw) cut off at the window's edge (\(file))")
            }
        }
    }
}

/// A click (or any step) and the time until the window stops changing: over the budget is lag.
struct Settles: Step {
    let inner: any Step
    var budget = LiveEyes.settleBudget
    var label: String { "\(inner.label), settled under \(budget) ms" }
    var timeout: Duration? { inner.timeout }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        let start = ContinuousClock.now
        func elapsed() -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
        }
        try await inner.run(story)
        // Settled when a frame matches the one before: timed at that earlier frame, so the
        // comparing (slow in a debug build) isn't counted as the app's lag.
        var previous = LiveEyes.frame(window)
        var previousAt = elapsed()
        var ms = 0
        var changes: [String] = []
        while true {
            try await story.idle()
            let next = LiveEyes.frame(window)
            let nextAt = elapsed()
            if let a = previous, let b = next, LiveEyes.identical(a, b) || LiveEyes.difference(a, b) == 0 {
                ms = previousAt
                break
            }
            // What still moved, and where, once it's running long: a lag's note names it.
            if nextAt > budget / 2, let a = previous, let b = next, let rect = LiveEyes.changed(a, b) {
                changes.append("\(nextAt) ms: \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
            }
            previous = next
            previousAt = nextAt
            ms = nextAt
            if nextAt > budget * 4 { break }
        }
        story.note("\(inner.label): settled in \(ms) ms" + (changes.isEmpty ? "" : "; changed " + changes.suffix(6).joined(separator: ", ")))
        if ms > budget {
            let file = previous.map { LiveEyes.save($0, "\(story.name)-lag", story) } ?? ""
            throw StoryFailure.other("lag: \(inner.label) \(ms) ms (\(file))")
        }
    }
}

extension StoryContext {
    /// A line for the run's detail log (`<out>/live-notes.txt`), never stdout.
    func note(_ line: String) {
        let url = outputs.appendingPathComponent("live-notes.txt")
        let text = "\(name): \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
