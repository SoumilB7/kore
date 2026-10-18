import AppKit
import SwiftUI

/// In-process navigation numbers for storylines: building answer rows (offscreen, never shown),
/// switching chat tabs and scrolling a transcript, each timed with the bench's frame clock
/// (`DevFramePacer`). The same code measures a change and the main it starts from.
@MainActor
package enum DevNavProbe {
    package struct Frames: Sendable {
        package var ms: [Double] = []
        package var frames = 0
        package var over33 = 0
        package var p95 = 0.0
        package var worst = 0.0
        package var px = 0.0
    }

    // MARK: Rows

    /// Builds `rows` answer rows as the timeline does (`TimelineRow`) in an offscreen window and
    /// lays them out: the time to the first layout and display.
    package static func buildRows(_ rows: Int, width: CGFloat = 760) -> Duration {
        let actions = rowActions()
        let items = (0..<rows).map { i in
            let entry = TranscriptStore.Entry(kind: .answer, text: sample(i), done: true)
            return TranscriptStore.Item(row: .entry(entry), dot: .plain, above: i > 0, below: i + 1 < rows, id: entry.id.uuidString)
        }
        let content = rowStack(VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { TimelineRow(item: $0, actions: actions).equatable() }
        }
        .frame(width: width))
        let window = NSWindow(
            contentRect: CGRect(x: -20000, y: -20000, width: width, height: 800), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let clock = ContinuousClock()
        let began = clock.now
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let took = clock.now - began
        window.contentView = nil
        window.close()
        return took
    }

    /// The actions a timeline hands its rows.
    private static func rowActions() -> TranscriptActions { TranscriptActions() }

    /// What the timeline puts around its rows: the selection they report to, in its space.
    private static func rowStack(_ rows: some View) -> some View {
        let selection = TranscriptSelection(store: nil)
        return rows
            .background(alignment: .topLeading) { SelectionResponder(selection: selection, hidden: false).frame(width: Stroke.hairline, height: Stroke.hairline) }
            .coordinateSpace(.named(TranscriptSelection.space))
            .environment(\.transcriptSelection, selection)
    }

    /// A typical answer: a heading, paragraphs with inline markup, a list, code and a table.
    package static func sample(_ i: Int) -> String {
        """
        ## Step \(i): what changes

        The **transcript** keeps its rows lazy, so a drag from one answer into the next has to \
        find text in rows that were built at different times. Inline `code`, *emphasis* and \
        [links](https://example.com/\(i)) keep their markup.

        - Rows report where their texts are.
        - The model holds the text: entry, block path, offset.
        - Copy rebuilds markdown from the entry's source, not from glyphs.
        - Item \(i) of a list long enough to wrap onto a second line in a column of normal width, as answers do.

        ```swift
        func hit(_ point: CGPoint) -> Int? {
            let row = rows.first { $0.frame.contains(point) }
            return row.map { $0.offset(at: point.x) }
        }
        ```

        | Option | Cost | Kept |
        |---|---|---|
        | frames per text | none | yes |
        | layouts per text | a third more | no |

        That's step \(i). The next one follows the same shape.
        """
    }

    // MARK: Tabs and scrolling

    /// Switches from each tab to the next `rounds` times; each switch timed to the first frame
    /// of three still ones with the new chat's rows on screen.
    package static func switchTabs(_ workspace: Workspace, rounds: Int) async -> Frames {
        guard let window = workspace.window, workspace.tabs.count > 1 else { return Frames() }
        let (pacer, scroll) = start(window, workspace)
        defer { pacer.stop() }
        var result = Frames()
        pacer.beginRecording()
        for _ in 0..<rounds {
            let index = workspace.tabs.firstIndex { $0 === workspace.activeTab } ?? 0
            let next = workspace.tabs[(index + 1) % workspace.tabs.count]
            let began = CACurrentMediaTime()
            workspace.select(next)
            scroll.value = nil
            guard let settled = await pacer.waitSettled(timeout: 10) else { break }
            result.ms.append((settled - began) * 1000)
            try? await Task.sleep(for: .milliseconds(150))
        }
        fill(&result, pacer.endRecording())
        return result
    }

    /// Scrolls the active transcript to the top, then back to the bottom, at `speed` px/s (the
    /// clip view moved a frame at a time; rows build as they enter).
    package static func scroll(_ workspace: Workspace, speed: Double = 3000) async -> Frames {
        guard let window = workspace.window else { return Frames() }
        let (pacer, scroll) = start(window, workspace)
        defer { pacer.stop() }
        guard let view = scroll.value ?? DevScroller.transcript(in: window) else { return Frames() }
        var result = Frames()
        _ = await pacer.waitSettled(timeout: 5)
        pacer.beginRecording()
        let up = await DevScroller.run(view, toTop: true, speed: speed, mode: .clip)
        let down = await DevScroller.run(view, toTop: false, speed: speed, mode: .clip)
        fill(&result, pacer.endRecording())
        result.px = up.movedPX + down.movedPX
        return result
    }

    private static func start(_ window: NSWindow, _ workspace: Workspace) -> (DevFramePacer, Held<NSScrollView?>) {
        let pacer = DevFramePacer()
        let scroll = Held<NSScrollView?>(nil)
        pacer.start(on: window.contentView ?? NSView()) {
            if scroll.value?.window !== window { scroll.value = DevScroller.transcript(in: window) }
            guard let view = scroll.value, let document = view.documentView else { return nil }
            let ready = workspace.activeTab.chat.map { !$0.transcript.sections.isEmpty } ?? true
            return DevFramePacer.Probe(height: document.frame.height, offset: DevScroller.offset(view), ready: ready)
        }
        return (pacer, scroll)
    }

    private static func fill(_ result: inout Frames, _ hitches: DevFramePacer.Hitches) {
        result.frames = hitches.frames
        result.over33 = hitches.over33
        result.p95 = hitches.p95MS
        result.worst = hitches.worstMS
    }
}
