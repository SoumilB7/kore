import AppKit
import KoreCore
import SwiftUI

// Parts every renderer shares (look §2, "Shared states").

/// A centred state: glyph, title, one line, buttons (phase 09 §7's states).
struct RendererState: View {
    var symbol = "doc"
    let title: String
    let line: String
    var buttons: [(String, () -> Void)] = []

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(Chrome.glyphState).foregroundStyle(Theme.tertiary)
            Text(title).font(Chrome.bodyMedium).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(line).font(Chrome.label).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: Space.md) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button(button.0, action: button.1).buttonStyle(SubtleButtonStyle())
                }
            }
        }
        .frame(maxWidth: Size.Editor.stateWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "data.csv is 212 MB.": over the renderer's limit.
    static func tooLarge(_ file: FileInfo, context: RendererContext) -> RendererState {
        RendererState(
            title: "\(file.url.lastPathComponent) is \(FileEditorView.size(Int(file.size))).",
            line: "Large files open as plain text.",
            buttons: [("Open as Text", context.openAsText), ("Reveal in Finder", { reveal(file.url) })])
    }

    /// The renderer failed on a file with no raw form (one with a raw form opens its source).
    static func cantRender(_ file: FileInfo, reason: String, context: RendererContext, hasRaw: Bool) -> RendererState {
        var buttons: [(String, () -> Void)] = []
        if hasRaw { buttons.append(("Show Source", context.showSource)) }
        buttons.append(("Open with Default App", { NSWorkspace.shared.open(file.url) }))
        return RendererState(title: "Kore can't show this file.", line: reason, buttons: buttons)
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// A spinner, only once loading has taken longer than `Motion.loadingDelay`.
struct RendererLoading: View {
    @StateObject private var shown = Local(false)

    var body: some View {
        ZStack {
            if shown.value {
                ProgressView().controlSize(.small).frame(width: Size.spinner, height: Size.spinner)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(Motion.loadingDelay))
            shown.value = true
        }
    }
}

/// What a renderer's load came to.
enum Loaded<Value> {
    case loading
    case ready(Value)
    case tooLarge
    case failed(String)
}

/// Reads a file's text off the main actor: UTF-8 (a BOM dropped), else UTF-16 with a BOM, else
/// Latin-1.
func readText(_ url: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
            let text = String(data: data, encoding: .utf16)
        {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }.value
}

// MARK: - The host's chrome

/// Preview | Source (look §2): both states as words, in one bordered box.
struct PreviewSourceSwitch: View {
    let rendering: FileRendering

    var body: some View {
        HStack(spacing: 0) {
            segment("Preview", selected: !rendering.showsRaw) { rendering.showsRaw = false }
            Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
            segment("Source", selected: rendering.showsRaw) { rendering.showsRaw = true }
        }
        .frame(height: Size.Segment.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .fixedSize()
    }

    /// The segment that isn't selected carries ⇧⌘V (VS Code's Markdown preview key), so the
    /// key always flips it.
    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SwitchSegment(title: title, selected: selected, action: action)
            .help(selected ? title : (title == "Preview" ? "Show Preview (⇧⌘V)" : "Show Source (⇧⌘V)"))
    }
}

private struct SwitchSegment: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Chrome.caption)
                .foregroundStyle(selected || hovered.value ? Theme.text : Theme.secondary)
                .padding(.horizontal, Size.Segment.padding)
                .frame(maxHeight: .infinity)
                .background(selected ? Theme.surfaceHover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only the other segment takes the key, so it always flips.
        .keyboardShortcut(selected ? nil : KeyboardShortcut("v", modifiers: [.command, .shift]))
        .onHover { hovered.value = $0 }
    }
}

/// The status row while a renderer shows: its facts, right-aligned (look §2).
struct RendererFacts: View {
    let facts: [String]

    var body: some View {
        HStack(spacing: Space.xl) {
            Spacer(minLength: 0)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                Text(fact).font(Chrome.captionDigits).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Size.Editor.statusInset)
        .frame(height: Size.Editor.statusRow)
    }
}

/// Over the source after a parse error: "This JSON couldn't be parsed: line 214. Showing the
/// source." (phase 09's notice bar, with a warning point).
struct RendererNotice: View {
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: Space.md) {
            Circle().fill(Theme.warning).frame(width: Size.statusPoint, height: Size.statusPoint)
            Text(message).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: Space.md)
            if let action {
                Button(action.title, action: action.run).buttonStyle(SubtleButtonStyle())
            }
        }
        .padding(.horizontal, Size.Editor.pathInset)
        .frame(height: Size.Editor.notice)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// KORE_TIME_RENDER=1: logs, per file tab, how long the renderer took from the tab's first look
/// at the file to its content being set, and to the first frame after that (stderr,
/// `RENDER <id> ready=… frame=…` in ms).
@MainActor enum RenderTiming {
    static let on = ProcessInfo.processInfo.environment["KORE_TIME_RENDER"] == "1"
    private static var start: ContinuousClock.Instant?

    static func begin() {
        guard on else { return }
        start = .now
    }

    static func ready(_ id: String) {
        guard on, let start else { return }
        self.start = nil
        let ready = ContinuousClock.now - start
        // The first time the main run loop goes idle after this: the frame has been committed.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            let frame = ContinuousClock.now - start
            FileHandle.standardError.write(Data("RENDER \(id) ready=\(ms(ready)) frame=\(ms(frame))\n".utf8))
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private nonisolated static func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }
}
