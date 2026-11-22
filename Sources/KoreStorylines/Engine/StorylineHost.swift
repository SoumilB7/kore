import AppKit
import KoreCore
import KoreLink
import KoreUI

/// Runs user storylines inside the app (phase 12): `kore-storylines` installs it, then starts
/// Kore as usual. Once the app has launched, the runner plays the chosen storylines, writes the
/// report, prints it and exits 0 when every one passed.
///
///     kore-storylines [--tag a,b] [--name A,B] [--provider claude|codex] [--list]
///                     [--out <dir>] [--size WxH] [--replay name|folder|agent:id;…]
///                     [--cli scripted|process] [--live <model>] [--record] [--fake-cli <path>]
///                     [--cassettes <dir>] [--real-input | --real-input-dry [--real-keys]]
@MainActor
package enum StorylineHost {
    private static var runner: Runner?
    private static var launched: NSObjectProtocol?

    /// Called by `kore-storylines` before `KoreApp.main()`, with the process's arguments.
    package static func install(arguments: [String]) {
        let options = Options(arguments)
        // Before anything reads them: the run's own Application Support, Logs and Caches, never
        // the owner's (the app's launch work prunes, migrates and forgets in them).
        KoreFolders.place(options.folders)
        // Kore's NSApp, as the app has it; any Objective-C exception AppKit catches and goes on
        // from fails the step it came in, with where it was thrown. Not by AppKit's
        // NSApplicationCrashOnExceptions: with that on, windows scroll otherwise than in the app
        // (OpenedChatLandsAtEndResized, 2026-11-24).
        KoreApplication.install()
        KoreApplication.reported = { Runner.exceptionReported($0) }
        AgentGrants.install()
        if options.list {
            for story in Runner.discover() {
                let tags = story.tags.map(\.name).sorted().joined(separator: ",")
                let variants = story.variants.map(\.name).filter { !$0.isEmpty }
                print("\(story.storyName)  [\(tags)]" + (variants.isEmpty ? "" : "  × \(variants.joined(separator: ", "))"))
            }
            exit(0)
        }
        // AppKit reads the arguments too, as `-key value` pairs, and takes one left over for a
        // file to open: a flag without a value (`--real-input --cassettes <dir>`) pairs with
        // the next flag and leaves that one's value over. Launched to open a file, the app
        // shows no window, so the welcome window never hands over the means to open a folder's.
        // A string: AppKit compares it as one, and a Bool here threw in `finishLaunching`.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        // The app's own story registry runs only under a host.
        StoryHost.installed = true
        StorylineSeams.events = { chat, event in Runner.current?.record(chat, event) }
        // Before anything can copy: the owner's clipboard is never written.
        GeneralPasteboardGuard.install()
        // A run happens out of sight unless it drives the real pointer.
        if !options.flags.realInput { OffscreenWindows.install() }
        let runner = Runner(selection: options.selection, flags: options.flags, out: options.out)
        self.runner = runner
        launched = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Offscreen and in the background, the host is App Nap's to slow down: its timers
                // and run loop held back for a minute and more mid-step. Not while it runs (the
                // Mac may still sleep when idle).
                let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Kore Dev: storylines")
                let report = await runner.run()
                ProcessInfo.processInfo.endActivity(activity)
                print(report.text)
                print("report: \(options.out.path)")
                fflush(stdout)
                exit(report.passed ? 0 : 1)
            }
        }
    }

    struct Options {
        var selection = Runner.Selection()
        var flags = RunFlags()
        var list = false
        var out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kore-storylines/\(Int(Date().timeIntervalSince1970))", isDirectory: true)

        init(_ arguments: [String]) {
            var args = arguments.dropFirst().makeIterator()
            while let arg = args.next() {
                switch arg {
                case "--tag": selection.tags = Set((args.next() ?? "").split(separator: ",").map { Tag(String($0)) })
                case "--name": selection.names = Set((args.next() ?? "").split(separator: ",").map(String.init))
                case "--provider": selection.provider = args.next()
                case "--drop": flags.drop = true
                case "--help", "-h":
                    print("kore-storylines --tag T | --name A,B | --list [--provider claude|codex] [--size WxH] [--out DIR] [--drop]")
                    exit(2)
                case "--list": list = true
                case "--out": out = URL(fileURLWithPath: args.next() ?? out.path, isDirectory: true)
                case "--cli": flags.cli = args.next() == "process" ? .process : .scripted
                case "--live": flags.cli = .live(model: args.next() ?? "haiku")
                case "--record": flags.record = true
                case "--fake-cli": flags.fakeCLI = args.next().map { URL(fileURLWithPath: $0) }
                case "--cassettes": flags.cassettes = args.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
                case "--real-input": flags.realInput = true
                case "--real-input-dry":
                    flags.realInput = true
                    flags.realInputDry = true
                case "--real-keys": flags.realKeys = true
                case "--size":
                    let wh = (args.next() ?? "").split(separator: "x").compactMap { Double($0) }
                    if wh.count == 2 { flags.size = CGSize(width: wh[0], height: wh[1]) }
                case "--replay":
                    // verify-landing's KORE_VERIFY_FIXTURES: "name|folder|agent:id;…".
                    for item in (args.next() ?? "").split(separator: ";") {
                        let parts = item.split(separator: "|").map(String.init)
                        if parts.count == 3 { flags.replays[parts[0]] = (URL(fileURLWithPath: parts[1], isDirectory: true), parts[2]) }
                    }
                default:
                    break  // AppKit's own arguments (-NSDocumentRevisionsDebugMode and the like)
                }
            }
            flags.realKeys = flags.realKeys && flags.realInput
        }

        /// The run's Kore folders: `<out>/kore-data/{support,logs,caches}`.
        var folders: KoreFolders.Places { KoreFolders.Places(under: out.appendingPathComponent("kore-data", isDirectory: true)) }
    }
}

/// Keeps every window the app shows off every screen, from the moment it's ordered in: one
/// that would land on a screen is moved away first, and AppKit isn't let to pull it back (a
/// titled window is kept partly on a screen otherwise). Nothing a storyline does needs it on
/// one: events go in-process and snapshots draw the window's own views.
@MainActor
enum OffscreenWindows {
    /// Below and left of any arrangement of displays.
    /// Its own stretch per process: parallel runs' windows never cover each other.
    static let origin = NSPoint(x: -30_000 - CGFloat(ProcessInfo.processInfo.processIdentifier % 64) * 3_000, y: -30_000)
    /// Windows let onto a screen (the energy bench's transparent "front" window).
    static var allowed: Set<ObjectIdentifier> = []

    private typealias Order = @convention(c) (NSWindow, Selector, NSWindow.OrderingMode, Int) -> Void

    /// `orderWindow(_:relativeTo:)` is the primitive every order-in goes through.
    static func install() {
        let order = #selector(NSWindow.order(_:relativeTo:))
        if let method = class_getInstanceMethod(NSWindow.self, order) {
            let original = unsafeBitCast(method_getImplementation(method), to: Order.self)
            let replacement: @convention(block) (NSWindow, NSWindow.OrderingMode, Int) -> Void = { window, place, other in
                if place != .out { MainActor.assumeIsolated { moveAway(window) } }
                original(window, order, place, other)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let constrain = #selector(NSWindow.constrainFrameRect(_:to:))
        if let method = class_getInstanceMethod(NSWindow.self, constrain) {
            let replacement: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// A window anchored to one already off screen (a popover) stays where it was put.
    private static func moveAway(_ window: NSWindow) {
        guard !allowed.contains(ObjectIdentifier(window)) else { return }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return }
        window.setFrameOrigin(origin)
    }
}
