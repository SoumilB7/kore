import AppKit
import SwiftUI

/// An image opened from a chip: zoom, pan, and mark it up with a pen before sending it.
@MainActor @Observable
final class ImageEditor: Identifiable {
    struct Stroke {
        let color: PenColor
        /// In image points, so it looks the same however far the image is zoomed.
        let width: CGFloat
        var points: [CGPoint]

        /// Smoothed through the midpoints of the sampled points.
        var path: CGPath {
            let path = CGMutablePath()
            guard let first = points.first else { return path }
            path.move(to: first)
            for (previous, point) in zip(points, points.dropFirst()) {
                path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
            }
            path.addLine(to: points[points.count - 1])
            return path
        }
    }

    enum PenColor: CaseIterable {
        case red, yellow, green, blue, white

        var nsColor: NSColor {
            switch self {
            case .red: NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
            case .yellow: NSColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
            case .green: NSColor(red: 0.2, green: 0.84, blue: 0.29, alpha: 1)
            case .blue: NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
            case .white: .white
            }
        }
    }

    let id = UUID()
    let image: NSImage
    /// The composer attachment this is, or nil for an image already sent.
    let pendingID: Attachment.ID?
    /// The original file, when there is one (Claude transcripts only keep the image data).
    let url: URL?

    var strokes: [Stroke] = [] { didSet { canvas?.needsDisplay = true } }
    var penOn = false { didSet { canvas?.penChanged() } }
    var color = PenColor.red
    /// Current magnification, for the percentage shown.
    var zoom: CGFloat = 1

    @ObservationIgnored weak var scrollView: ImageScrollView?
    @ObservationIgnored weak var canvas: ImageCanvasView?

    init?(_ attachment: Attachment, pending: Bool) {
        guard let image = attachment.url.flatMap(NSImage.init(contentsOf:)) ?? attachment.thumbnail,
            image.size.width > 0, image.size.height > 0
        else { return nil }
        self.image = image
        pendingID = pending ? attachment.id : nil
        url = attachment.url
    }

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes.removeAll() }

    func zoomIn() { scrollView?.zoom(by: 1.25) }
    func zoomOut() { scrollView?.zoom(by: 0.8) }
    func zoomToFit() { scrollView?.fit() }
    func actualSize() { scrollView?.setZoom(1) }

    /// The image with its markup, at full resolution, as a new PNG file.
    func render() -> URL? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let height = CGFloat(cgImage.height)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: height))
        // Strokes are in image points, top-left origin.
        let scale = CGFloat(cgImage.width) / image.size.width
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        for stroke in strokes { Self.draw(stroke, in: context) }
        guard let output = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
        else { return nil }
        return Attachments.saveImage(png)
    }

    static func draw(_ stroke: Stroke, in context: CGContext) {
        context.addPath(stroke.path)
        context.setStrokeColor(stroke.color.nsColor.cgColor)
        context.setLineWidth(stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}

/// The modal over the chat: the image, a close button, and a toolbar along the bottom.
struct ImageViewer: View {
    let editor: ImageEditor
    /// "Done" for a composer image (applies the markup), "Add to message" for a sent one.
    let actionTitle: String
    let finish: () -> Void
    let close: () -> Void
    @StateObject private var keyMonitor = Local<Any?>(nil)

    var body: some View {
        ZStack {
            Theme.background
            ImageCanvas(editor: editor)
                .padding(.top, 44)
                .padding(.bottom, 68)
                .padding(.horizontal, 24)
            VStack {
                HStack {
                    Spacer()
                    toolButton("xmark", help: "Close (Esc)", action: close)
                }
                .padding(10)
                Spacer()
                toolbar.padding(.bottom, 16)
            }
        }
        .transition(.opacity)
        .onAppear {
            keyMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
    }

    /// While open, the viewer has this window's keys (whatever holds focus underneath): Esc
    /// closes, Return finishes, ⌘Z undoes a stroke, ⌘= ⌘- ⌘0 zoom the image instead of the
    /// text. Other plain keys are swallowed so nothing types into the hidden composer;
    /// other ⌘ shortcuts (⌘W, ⌘T…) still work.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = editor.canvas?.window, event.window === window else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            guard flags.subtracting(.shift) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "z": editor.undo()
            case "=", "+": editor.zoomIn()
            case "-": editor.zoomOut()
            case "0": editor.zoomToFit()
            default: return event
            }
            return nil
        }
        switch event.keyCode {
        case 53: close()
        case 36, 76: finish()
        default: break
        }
        return nil
    }

    /// Full in a roomy window; in a narrow tile it drops the percentage, folds the pen colours
    /// into one swatch menu, and at the smallest keeps only zoom-to-fit, pen, undo and the action.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(.full)
            toolbarRow(.compact)
            toolbarRow(.minimal)
        }
        .padding(.horizontal, 12)
    }

    private enum Density { case full, compact, minimal }

    private func toolbarRow(_ density: Density) -> some View {
        HStack(spacing: 2) {
            if density != .minimal {
                toolButton("minus.magnifyingglass", help: "Zoom out (⌘-)", action: editor.zoomOut)
            }
            if density == .full {
                Button(action: editor.actualSize) {
                    Text("\(Int((editor.zoom * 100).rounded()))%")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 44, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Actual size")
            }
            if density != .minimal {
                toolButton("plus.magnifyingglass", help: "Zoom in (⌘=)", action: editor.zoomIn)
            }
            toolButton("arrow.up.left.and.arrow.down.right", help: "Fit (⌘0)", action: editor.zoomToFit)
            divider
            toolButton("pencil", help: "Pen", isOn: editor.penOn) { editor.penOn.toggle() }
            if editor.penOn {
                if density == .full {
                    ForEach(ImageEditor.PenColor.allCases, id: \.self) { color in
                        Button {
                            editor.color = color
                        } label: {
                            swatch(color, selected: editor.color == color)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Menu {
                        ForEach(ImageEditor.PenColor.allCases, id: \.self) { color in
                            Button(String(describing: color).capitalized) { editor.color = color }
                        }
                    } label: {
                        swatch(editor.color, selected: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pen colour")
                }
            }
            toolButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: editor.undo)
                .disabled(editor.strokes.isEmpty)
            if density != .minimal {
                toolButton("trash", help: "Clear markup", action: editor.clear)
                    .disabled(editor.strokes.isEmpty)
            }
            divider
            Button(actionTitle, action: finish)
                .buttonStyle(SubtleButtonStyle(prominent: true))
                .lineLimit(1)
                .fixedSize()
                .help("\(actionTitle) (Return)")
                .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func swatch(_ color: ImageEditor.PenColor, selected: Bool) -> some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Theme.text, lineWidth: selected ? 1.5 : 0).padding(-3))
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 6)
    }

    private func toolButton(_ symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        ToolButton(symbol: symbol, isOn: isOn, action: action).help(help)
    }
}

private struct ToolButton: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Theme.text : (isEnabled ? Theme.secondary : Theme.tertiary))
                .frame(width: 28, height: 28)
                .background(
                    isOn ? Theme.surfaceHover : (hovered.value && isEnabled ? Theme.surfaceHover.opacity(0.6) : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

// MARK: - AppKit canvas

/// NSScrollView gives native pinch-to-zoom and scrolling; the document view draws the image
/// and the strokes and takes the pen.
private struct ImageCanvas: NSViewRepresentable {
    let editor: ImageEditor

    func makeNSView(context: Context) -> ImageScrollView {
        let canvas = ImageCanvasView(editor: editor)
        let scrollView = ImageScrollView(editor: editor)
        scrollView.documentView = canvas
        editor.scrollView = scrollView
        editor.canvas = canvas
        return scrollView
    }

    func updateNSView(_ nsView: ImageScrollView, context: Context) {}
}

final class ImageScrollView: NSScrollView {
    private let editor: ImageEditor
    /// Still at "fit": keep fitting as the window resizes.
    private var fitting = true

    init(editor: ImageEditor) {
        self.editor = editor
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 16
        NotificationCenter.default.addObserver(
            self, selector: #selector(userMagnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    /// Whole image visible, never enlarged past actual size.
    func fit() {
        guard let document = documentView, bounds.width > 0, bounds.height > 0 else { return }
        let size = document.frame.size
        setZoom(min(1, bounds.width / size.width, bounds.height / size.height), fitting: true)
    }

    func zoom(by factor: CGFloat) { setZoom(magnification * factor) }

    func setZoom(_ value: CGFloat, fitting: Bool = false) {
        self.fitting = fitting
        // Keep what's in the middle of the view in the middle.
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        magnification = min(max(value, minMagnification), maxMagnification)
        let size = contentView.bounds.size
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: size)).origin)
        reflectScrolledClipView(contentView)
        editor.zoom = magnification
    }

    @objc private func userMagnified() {
        fitting = false
        editor.zoom = magnification
    }
}

/// Centers the image while it is smaller than the view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

final class ImageCanvasView: NSView {
    private let editor: ImageEditor
    private var current: ImageEditor.Stroke?
    private var dragStart: NSPoint?

    init(editor: ImageEditor) {
        self.editor = editor
        super.init(frame: NSRect(origin: .zero, size: editor.image.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        editor.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for stroke in editor.strokes { ImageEditor.draw(stroke, in: context) }
        if let current { ImageEditor.draw(current, in: context) }
    }

    func penChanged() { window?.invalidateCursorRects(for: self) }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: editor.penOn ? .crosshair : .openHand)
    }

    // MARK: Mouse: the pen draws; otherwise drag pans and double-click toggles fit / 100%.

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if editor.penOn {
            let magnification = enclosingScrollView?.magnification ?? 1
            current = .init(color: editor.color, width: 3.5 / magnification, points: [clamped(point)])
            needsDisplay = true
        } else if event.clickCount == 2, let scrollView = enclosingScrollView as? ImageScrollView {
            if abs(scrollView.magnification - 1) < 0.01 { scrollView.fit() } else { scrollView.setZoom(1) }
        } else {
            dragStart = event.locationInWindow
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if current != nil {
            current?.points.append(clamped(convert(event.locationInWindow, from: nil)))
            needsDisplay = true
        } else if let start = dragStart, let clip = enclosingScrollView?.contentView {
            let magnification = enclosingScrollView?.magnification ?? 1
            var origin = clip.bounds.origin
            origin.x -= (event.locationInWindow.x - start.x) / magnification
            origin.y += (event.locationInWindow.y - start.y) / magnification
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
            dragStart = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let current {
            editor.strokes.append(current)
            self.current = nil
        }
        if dragStart != nil {
            dragStart = nil
            NSCursor.pop()
        }
    }

    private func clamped(_ point: NSPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
}
