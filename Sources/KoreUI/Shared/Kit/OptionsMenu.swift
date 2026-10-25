import AppKit
import Observation
import SwiftUI

/// Menu data shared by pointer menus, compact pickers and native text controls.
@MainActor
struct OptionItem {
    let title: String
    var enabled = true
    var checked = false
    var destructive = false
    /// Optional semantic text colour for file-status rows; ordinary menu actions stay neutral.
    var tint: Color?
    var children: [OptionItem] = []
    var action: (() -> Void)?
    /// A symbol before the title, and the key that does the same, after it (learnt by being seen).
    var glyph: String?
    var key: String?
    var separator: Bool { title.isEmpty && action == nil && children.isEmpty }

    init(_ title: String, enabled: Bool = true, checked: Bool = false, destructive: Bool = false, tint: Color? = nil,
         glyph: String? = nil, key: String? = nil, children: [OptionItem] = [], action: (() -> Void)? = nil) {
        self.glyph = glyph
        self.key = key
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.destructive = destructive
        self.tint = tint
        self.children = children
        self.action = action
    }
    static var rule: Self { Self("") }
}

@MainActor
extension Array where Element == OptionItem {
    /// Rules only between entries: none first or last, and a run of them one (a native menu's
    /// hidden items leave the rules around them side by side).
    var ruled: [OptionItem] {
        var kept: [OptionItem] = []
        for item in self where !(item.separator && kept.last?.separator ?? true) { kept.append(item) }
        if kept.last?.separator == true { kept.removeLast() }
        return kept
    }
}

/// One in-window menu at a time. Opening it keeps the editor/transcript's first responder,
/// so Copy, Paste and selection continue to target the original view.
@MainActor @Observable
final class OptionsMenu {
    static let shared = OptionsMenu()
    private(set) var items: [OptionItem] = []
    private(set) var selected: Int?
    private(set) var parents: [[OptionItem]] = []
    @ObservationIgnored private weak var owner: NSWindow?
    @ObservationIgnored private var host: NSHostingView<OptionsList>?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var nativeMenu: NSMenu?
    @ObservationIgnored private var anchor = CGPoint.zero
    @ObservationIgnored private var source = ""
    @ObservationIgnored private static var nativeMonitor: Any?

    static func install() {
        guard nativeMonitor == nil else { return }
        nativeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window = event.window, let content = window.contentView,
                  shared.retargetContextClick(event) else { return event }
            if let responder = window.firstResponder as? SelectionResponderView,
               responder.selection?.hasSelection == true, let scroll = responder.enclosingScrollView,
               scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) { return event }
            var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            while let current = view {
                if current is EditorTextView { break }
                if let text = current as? NSTextView {
                    guard Self.prepareTextContext(text, event: event) else { return event }
                    if let menu = text.menu(for: event), shared.showNative(menu, event: event, view: text) { return nil }
                    break
                }
                view = current.superview
            }
            let targets = ContextOptions.Target.all.allObjects.filter {
                let point = $0.convert(event.locationInWindow, from: nil)
                return $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                    && $0.bounds.contains(point) && $0.visibleRect.contains(point)
            }
            // A modal's own menu, over whatever it covers.
            let shown = targets.contains(where: \.modal) ? targets.filter(\.modal) : targets
            if let target = shown.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                target.show(event)
                return nil
            }
            return event
        }
    }

    /// An outside secondary click both dismisses this menu and opens the new target's.
    /// Inside clicks stay with the hosting view rather than the surface beneath it.
    func retargetContextClick(_ event: NSEvent) -> Bool {
        if let host, event.window === owner,
           host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { return false }
        close()
        return true
    }

    /// The local monitor consumes the native press, so perform its focus and word selection
    /// before AppKit constructs/validates a text menu. An existing selection stays intact.
    static func prepareTextContext(_ text: NSTextView, event: NSEvent) -> Bool {
        guard text.isSelectable, text.window?.makeFirstResponder(text) == true else { return false }
        let length = (text.string as NSString).length
        let index = min(length, text.characterIndexForInsertion(at: text.convert(event.locationInWindow, from: nil)))
        if !text.selectedRanges.contains(where: { NSLocationInRange(index, $0.rangeValue) }) {
            let range = NSRange(location: index, length: 0)
            text.setSelectedRange(length == 0 ? range : text.selectionRange(forProposedRange: range, granularity: .selectByWord))
        }
        return true
    }

    @discardableResult
    func showNative(_ menu: NSMenu, event: NSEvent, view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let entries = Self.nativeItems(menu, source: view)
        guard !entries.isEmpty else { return false }
        show(entries, at: event.locationInWindow, in: window, source: "text")
        nativeMenu = menu
        return true
    }

    private static func nativeItems(_ menu: NSMenu, source: NSView) -> [OptionItem] {
        menu.delegate?.menuNeedsUpdate?(menu)
        // Right-clicks can arrive before the source window becomes key. Validate text
        // commands against their source rather than another window's responder chain.
        for item in menu.items where item.target == nil {
            if let selector = item.action, source.responds(to: selector) { item.target = source }
        }
        let submenus = Dictionary(uniqueKeysWithValues: menu.items.compactMap { item -> (ObjectIdentifier, [OptionItem])? in
            guard let submenu = item.submenu else { return nil }
            return (ObjectIdentifier(item), nativeItems(submenu, source: source))
        })
        menu.update()
        return menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return .rule }
            let action: (() -> Void)? = item.action.flatMap { selector in
                guard let target = NSApp.target(forAction: selector, to: item.target, from: item) else { return nil }
                return { withExtendedLifetime(menu) { _ = NSApp.sendAction(selector, to: target, from: item) } }
            }
            return OptionItem(item.title, enabled: item.isEnabled, checked: item.state == .on,
                              children: submenus[ObjectIdentifier(item)] ?? [], action: action)
        }
    }

    func show(_ entries: [OptionItem], at point: CGPoint, in window: NSWindow, source: String) {
        close()
        let entries = entries.ruled
        guard !entries.isEmpty, window.contentView != nil else { return }
        owner = window
        items = entries
        parents = []
        selected = nil
        anchor = point
        self.source = source
        let host = NSHostingView(rootView: OptionsList(menu: self))
        host.setAccessibilityRole(.menu)
        self.host = host
        window.contentView?.addSubview(host)
        place()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification,
                     NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        UILog.event("options-open", ["source": source])
    }

    private func place() {
        guard let content = owner?.contentView, let host else { return }
        let height = min(Size.menuMax, CGFloat(items.filter { !$0.separator }.count + (parents.isEmpty ? 0 : 1)) * Layout.Options.row
                         + CGFloat(items.filter(\.separator).count) * (Stroke.hairline + Space.xs * 2) + Space.xs * 2)
        let point = content.convert(anchor, from: nil)
        host.frame = Self.fitting(point: point, size: CGSize(width: Layout.Options.width, height: height),
                                  bounds: content.bounds, flipped: content.isFlipped)
    }

    static func fitting(point: CGPoint, size: CGSize, bounds: CGRect, flipped: Bool) -> CGRect {
        let room = bounds.insetBy(dx: Space.sm, dy: Space.sm)
        let width = min(size.width, max(0, room.width)), height = min(size.height, max(0, room.height))
        return CGRect(x: min(max(point.x, room.minX), room.maxX - width),
                      y: min(max(flipped ? point.y : point.y - height, room.minY), room.maxY - height), width: width, height: height)
    }

    func hover(_ index: Int) { if items[index].enabled && !items[index].separator { selected = index } }

    func choose(_ index: Int) {
        guard items.indices.contains(index), items[index].enabled, !items[index].separator else { return }
        let item = items[index]
        if !item.children.isEmpty {
            parents.append(items)
            items = item.children.ruled
            selected = nil
            place()
        } else if let action = item.action {
            UILog.event("options-pick", ["source": source, "item": String(index)])
            close()
            action()
        }
    }

    func back() {
        guard let previous = parents.popLast() else { return }
        items = previous
        selected = nil
        place()
    }

    func close() {
        host?.removeFromSuperview()
        host = nil
        nativeMenu = nil
        owner = nil
        items = []
        parents = []
        selected = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let owner, let host else { return event }
        guard event.window === owner else { close(); return event }
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: close()
            case 123: if parents.isEmpty { close() } else { back() }
            case 124: if let selected, !items[selected].children.isEmpty { choose(selected) }
            case 36, 76, 49: if let selected { choose(selected) }
            case 125, 126, 48:
                let backwards = event.keyCode == 126 || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
                let available = items.indices.filter { items[$0].enabled && !items[$0].separator }
                if !available.isEmpty {
                    let current = selected.flatMap { available.firstIndex(of: $0) }
                    let next = current.map { ($0 + (backwards ? available.count - 1 : 1)) % available.count }
                        ?? (backwards ? available.count - 1 : 0)
                    selected = available[next]
                }
            default:
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   let text = event.charactersIgnoringModifiers, !text.isEmpty,
                   let match = items.indices.first(where: { items[$0].enabled && !items[$0].separator && items[$0].title.localizedLowercase.hasPrefix(text.localizedLowercase) }) {
                    selected = match
                } else { close(); return event }
            }
            return nil
        }
        if event.type == .scrollWheel {
            if !host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { close() }
        } else if !host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { close() }
        return event
    }
}

private struct OptionsList: View {
    let menu: OptionsMenu
    /// The check column, kept only while an entry has a mark (a check, or Back's chevron):
    /// otherwise labels start at a row's own inset, as Kore's other lists do.
    private var gutter: Bool { !menu.parents.isEmpty || menu.items.contains(where: \.checked) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !menu.parents.isEmpty {
                        Button(action: menu.back) { label("Back", symbol: "chevron.left", tint: Theme.secondary) }
                            .buttonStyle(.plain)
                            .storyID(StoryID.Options.back)
                    }
                    ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                        if item.separator {
                            Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs)
                        } else {
                            Button { menu.choose(index) } label: {
                                label(item.title, symbol: item.checked ? "checkmark" : nil,
                                      tint: !item.enabled ? Theme.tertiary : item.destructive ? Theme.danger : item.tint ?? Theme.text,
                                      branch: !item.children.isEmpty, glyph: item.glyph, key: item.key)
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.enabled)
                            .help(item.title)
                            .accessibilityAddTraits(item.checked ? .isSelected : [])
                            .background(menu.selected == index ? Theme.Row.selected(.surface) : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                            .onHover { if $0 { menu.hover(index) } }
                            .id(index)
                            .storyID(StoryID.Options.item(index))
                        }
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: menu.selected) { _, index in if let index { proxy.scrollTo(index) } }
        }
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .preferredColorScheme(.dark)
        .storyMark(StoryID.Options.panel)
    }

    private func label(_ text: String, symbol: String?, tint: SwiftUI.Color, branch: Bool = false, glyph: String? = nil, key: String? = nil) -> some View {
        HStack(spacing: Space.sm) {
            if gutter { Image(systemName: symbol ?? "checkmark").opacity(symbol == nil ? 0 : 1).font(Chrome.glyphCrumb) }
            if let glyph { Image(systemName: glyph).font(Chrome.caption).foregroundStyle(Theme.secondary) }
            Text(text).font(Chrome.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let key { Text(key).font(Chrome.caption).foregroundStyle(Theme.tertiary).padding(.leading, Space.lg) }
            if branch { Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ContextOptions: NSViewRepresentable {
    let items: () -> [OptionItem]
    let source: String
    var modal = false
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) { view.items = items; view.source = source; view.modal = modal }
    final class Target: NSView {
        static let all = NSHashTable<Target>.weakObjects()
        var items: (() -> [OptionItem])?
        var source = ""
        /// Over the rest of the window (the image viewer): it wins over the targets it covers.
        var modal = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Self.all.remove(self) } else { Self.all.add(self) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func show(_ event: NSEvent) {
            guard let window else { return }
            OptionsMenu.shared.show(items?() ?? [], at: event.locationInWindow, in: window, source: source)
        }
    }
}

extension View {
    func koreContextMenu(_ source: String, modal: Bool = false, items: @escaping () -> [OptionItem]) -> some View {
        overlay { ContextOptions(items: items, source: source, modal: modal).accessibilityHidden(true) }
    }
}

struct OptionMenuButton<Label: View>: View {
    let source: String
    let items: () -> [OptionItem]
    @ViewBuilder let label: () -> Label
    @StateObject private var anchor = Held(WeakAnchor())
    var body: some View {
        Button {
            guard let view = anchor.value.view, let window = view.window else { return }
            let point = view.convert(CGPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY), to: nil)
            OptionsMenu.shared.show(items(), at: point, in: window, source: source)
        } label: {
            HStack(spacing: Space.xs) { label(); Image(systemName: "chevron.down").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary) }
        }
        .buttonStyle(.plain)
        .background(AnchorView(anchor: anchor.value))
    }
    private final class WeakAnchor { weak var view: NSView? }
    private struct AnchorView: NSViewRepresentable {
        let anchor: WeakAnchor
        func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}

extension Layout {
    enum Options { static let width: CGFloat = 280; static let row: CGFloat = 28 }
}
extension StoryID {
    package enum Options {
        package static let panel = StoryID(.editor, "options")
        package static let back = panel.part(.previous)
        package static func item(_ index: Int) -> StoryID { StoryID(.editor, "options.item", key: String(index)) }
    }
}
