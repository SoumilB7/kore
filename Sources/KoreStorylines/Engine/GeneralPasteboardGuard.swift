import AppKit
import KoreUI
import ObjectiveC

/// The owner's clipboard is never a storyline's. `NSPasteboard.general` answers with the host's
/// own board (so AppKit's copy and paste work there); a write to the general board reached
/// another way (by its name) goes to the host's board too, and is noted with its caller, so the
/// storyline that made it fails by name.
/// Only this process's writes: another app's copy, or a parallel run's, isn't counted.
@MainActor
enum GeneralPasteboardGuard {
    /// Writes caught since the last `take()`: the method and the first app frames that called it.
    nonisolated(unsafe) private static var caught: [String] = []
    /// The host's board, looked up once: `NSPasteboard.general` is asked for often (the text
    /// system asks on every edit), and a lookup per ask slowed the main thread enough to miss a
    /// composer's shrink after its draft was cleared.
    nonisolated(unsafe) private static let host = NSPasteboard(name: StoryHost.board)
    private static var installed = false

    static func install() {
        guard !installed, ProcessInfo.processInfo.environment["KORE_STORY_NO_BOARD_GUARD"] == nil else { return }
        installed = true
        // `NSPasteboard.general` is the host's board: AppKit's own copy and paste (a text view's
        // ⌘C then ⌘V) read and write it there, the owner's clipboard untouched.
        if let general = class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)) {
            let host: @convention(block) (AnyObject) -> NSPasteboard = { _ in Self.host }
            method_setImplementation(general, imp_implementationWithBlock(host))
        }
        redirect(#selector(NSPasteboard.clearContents), as: (@convention(c) (NSPasteboard, Selector) -> Int).self) { was, sel in
            { (board: NSPasteboard) -> Int in was(target(board, sel), sel) } as @convention(block) (NSPasteboard) -> Int
        }
        redirect(#selector(NSPasteboard.declareTypes(_:owner:)), as: (@convention(c) (NSPasteboard, Selector, NSArray, AnyObject?) -> Int).self) { was, sel in
            { (board: NSPasteboard, types: NSArray, owner: AnyObject?) -> Int in was(target(board, sel), sel, types, owner) }
                as @convention(block) (NSPasteboard, NSArray, AnyObject?) -> Int
        }
        redirect(#selector(NSPasteboard.writeObjects(_:)), as: (@convention(c) (NSPasteboard, Selector, NSArray) -> Bool).self) { was, sel in
            { (board: NSPasteboard, objects: NSArray) -> Bool in was(target(board, sel), sel, objects) } as @convention(block) (NSPasteboard, NSArray) -> Bool
        }
        redirect(#selector(NSPasteboard.setString(_:forType:)), as: (@convention(c) (NSPasteboard, Selector, NSString, NSString) -> Bool).self) { was, sel in
            { (board: NSPasteboard, string: NSString, type: NSString) -> Bool in was(target(board, sel), sel, string, type) }
                as @convention(block) (NSPasteboard, NSString, NSString) -> Bool
        }
        redirect(#selector(NSPasteboard.setData(_:forType:)), as: (@convention(c) (NSPasteboard, Selector, NSData?, NSString) -> Bool).self) { was, sel in
            { (board: NSPasteboard, data: NSData?, type: NSString) -> Bool in was(target(board, sel), sel, data, type) }
                as @convention(block) (NSPasteboard, NSData?, NSString) -> Bool
        }
    }

    /// The writes caught since the last call.
    static func take() -> [String] {
        defer { caught = [] }
        return caught
    }

    /// The host's own board in place of the general one, the write noted.
    nonisolated private static func target(_ board: NSPasteboard, _ selector: Selector) -> NSPasteboard {
        guard board.name == .general else { return board }
        let frames = Thread.callStackSymbols.dropFirst(2).filter { $0.contains("Kore") || $0.contains("AppKit") }.prefix(4)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
        caught.append("\(NSStringFromSelector(selector)) from \(frames.joined(separator: " ← "))")
        return host
    }

    private static func redirect<C>(_ selector: Selector, as _: C.Type, _ make: (C, Selector) -> Any) {
        guard let method = class_getInstanceMethod(NSPasteboard.self, selector) else { return }
        let was = unsafeBitCast(method_getImplementation(method), to: C.self)
        method_setImplementation(method, imp_implementationWithBlock(make(was, selector)))
    }
}
