import AppKit
import KoreCore

/// Debug hook for checking the UI without clicking through it:
///   KORE_OPEN=<folder>       open that folder's window at launch
///   KORE_START=claude|codex  start a chat of that provider in its first tab
///   KORE_RESUME=<agent>:<id>[,<agent>:<id>...] open those past sessions instead, one tab each
///   KORE_SEND=<text>         send that message in the started or resumed chat (KORE_SEND_AFTER=<s>, resumed only)
///   KORE_MODE=<mode id>      switch the started chat to that mode
///   KORE_MODEL=<model>       launch the started or resumed chat on that model (haiku / gpt-6-luna keep tests cheap)
///   KORE_ATTACH=<path>[:...] attach those files to the started chat's composer
///   KORE_PASTE=1             press ⌘V (a real key event) in the composer
///   KORE_THEN_SEND=<text>    after that, send this text with whatever got attached
///   KORE_FULLSCREEN=1        enter full screen before the snapshot
///   KORE_DRAG=<x>,<y>,<dx>,<dy> real drag from that point (after any clicks); logs the window's move to stderr
///   KORE_KEYS=<code>[;cmd+shift+<code>...] key presses (cmd, shift, opt, ctrl) (virtual key codes) after the clicks and drag, 0.5s apart,
///                            delivered inside Kore; KORE_REAL_KEYS=1 posts them through the window server
///                            instead (they then go to whatever app is frontmost)
///   KORE_CLICK=<x>,<y>[;...] click those points (from the window's top-left), 1s apart, before the snapshot
///   KORE_CLICK_AFTER=<s>     start those clicks that many seconds after launch (default 2.5; a replay needs ~8)
///   KORE_REAL_CLICK=1        post that click through the window server (moves the real cursor),
///                            to catch title-bar regions that swallow clicks
///   KORE_HISTORY=1           open the history panel at launch
///   KORE_VIEW_IMAGE=1        open the first composer attachment in the image viewer
///   KORE_SIZE=<w>,<h>        resize the folder window's content first (tile-size checks)
///   KORE_HANGS=1|<ms>        log main-thread stalls over 50ms (or <ms>) and each click/key, with times, to
///                            stderr; a stall past 250ms also prints STALL-START <pid> once, so a script can
///                            `sample` it. Watched in the common run-loop modes (through tracking and resize)
///   KORE_SNAPSHOT=<png path> once a folder window is up, save an image of it and quit
///   KORE_DUMP=<path>         write the chat's transcript entries as text and quit (KORE_DUMP_AFTER=<s>, default 6)
///   KORE_EVENT_LOG=<path>    append every ChatEvent the backend emits, one per line
///   KORE_TIME_REPLAY=1       print how long applying a resumed session's past took (main thread)
///   KORE_STOP_AFTER=<s>      press Stop that many seconds after launch
///   KORE_STOP_AGENT_AFTER=<s> stop the first running sub-agent (its card's Stop) that many seconds after launch
///   KORE_SEND_AFTER_STOP=<text> send that 3s after either stop
///   KORE_SET_MODE=<id>@<s>[;…] switch the chat's mode that many seconds after launch, as the mode
///                            menu does (plan-on / plan-off toggle Codex's Plan)
///   KORE_ANSWER=allow|always|deny  answer every approval as it appears
///   KORE_FORK=<n>            fork the opened chat from its nth user message (once its CLI is up); KORE_FORK_SEND=<text>
///                            then sends that text in the fork's tab
///   KORE_EARLIER=top|load    after KORE_EARLIER_AFTER seconds (default 4), scroll the transcript to its
///                            top; with load, then press the top row KORE_EARLIER_TIMES times (default 1); then
///                            KORE_EARLIER_SHOW=divider|top scrolls to the first divider or the top
///   KORE_EXPLORER=1          open the explorer at launch
///   KORE_FILE=<path>[:...]   open those files in tabs (the last one shown); KORE_PREVIEW=1 opens them as preview tabs
///   KORE_QUICK_OPEN=files|line  open quick open at launch
///   KORE_LINE=<n>            put the caret on that line of the shown file
///   KORE_SEARCH=<query>      open the sidebar on Search with that query
///   KORE_RESIZE_SWEEP=<from>,<to>,<s>[,<start>]  after 4s (or <start>), resize the window's width from one to the other and
///                            back over that many seconds, a frame at a time, inside Kore (a drag's
///                            relayouts without the pointer); pair with KORE_HANGS=1; logs frames
///   KORE_TAB_SWITCH=<n>      after 4s, select the next tab n times, 0.25s apart (prints the CPU time it took)
///   KORE_CLOSE_AFTER=<s>     ask the folder window to close (as ⌘W does) that many seconds after launch
///   KORE_CONTEXT=<used>,<window>[,compacting]  give the chat that context usage (the wheel) after
///                            KORE_CONTEXT_AFTER seconds (default 6); KORE_CONTEXT_CARD=1 holds its hover card open
enum DevSnapshot {
    static let openFolder = ProcessInfo.processInfo.environment["KORE_OPEN"].map { URL(fileURLWithPath: $0) }
    static let startProvider = ProcessInfo.processInfo.environment["KORE_START"].flatMap(Provider.init(rawValue:))
    /// KORE_RESUME, one session per comma.
    static let resumes: [SessionSummary] = (ProcessInfo.processInfo.environment["KORE_RESUME"] ?? "")
        .split(separator: ",").compactMap { value in
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let agent = SessionSummary.Agent(rawValue: parts[0]) else { return nil }
            return SessionSummary(id: parts[1], agent: agent, title: "Resumed", updated: .now)
        }
    static var resume: SessionSummary? { resumes.first }
    static let send = ProcessInfo.processInfo.environment["KORE_SEND"]
    static let mode = ProcessInfo.processInfo.environment["KORE_MODE"]
    static let thenSend = ProcessInfo.processInfo.environment["KORE_THEN_SEND"]
    static let model = ProcessInfo.processInfo.environment["KORE_MODEL"]
    /// KORE_HISTORY=1: open the history panel at launch. KORE_VIEW_IMAGE=1: open the first
    /// composer attachment in the image viewer. (Deterministic snapshots without real clicks.)
    static let openHistory = ProcessInfo.processInfo.environment["KORE_HISTORY"] == "1"
    static let viewImage = ProcessInfo.processInfo.environment["KORE_VIEW_IMAGE"] == "1"
    static let explorer = ProcessInfo.processInfo.environment["KORE_EXPLORER"] == "1"
    static let files = (ProcessInfo.processInfo.environment["KORE_FILE"] ?? "").split(separator: ":").map {
        URL(fileURLWithPath: String($0))
    }
    static let quickOpen = ProcessInfo.processInfo.environment["KORE_QUICK_OPEN"]
    static let line = ProcessInfo.processInfo.environment["KORE_LINE"].flatMap { Int($0) }
    static let search = ProcessInfo.processInfo.environment["KORE_SEARCH"]
    static let tabSwitches = ProcessInfo.processInfo.environment["KORE_TAB_SWITCH"].flatMap { Int($0) }

    /// KORE_TAB_SWITCH: cycles the tabs, timing the process's CPU across it.
    @MainActor static func switchTabs(_ count: Int, in workspace: Workspace) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Task { @MainActor in
                let start = ProcessInfo.processInfo.systemUptime
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let cpu0 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                for _ in 0..<count {
                    let index = workspace.tabs.firstIndex { $0.id == workspace.activeID } ?? 0
                    workspace.select(workspace.tabs[(index + 1) % workspace.tabs.count])
                    try? await Task.sleep(for: .milliseconds(250))
                }
                getrusage(RUSAGE_SELF, &usage)
                let cpu1 = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                FileHandle.standardError.write(Data(String(format: "TABS %d switches: cpu %.2fs over %.2fs\n", count, cpu1 - cpu0, ProcessInfo.processInfo.systemUptime - start).utf8))
            }
        }
    }
    static let attach = ProcessInfo.processInfo.environment["KORE_ATTACH"].map {
        $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }
    /// Runs that start or resume a chat keep one tab instead of loading the folder's chats.
    static var singleTab: Bool { startProvider != nil || resume != nil }
    private static let output = ProcessInfo.processInfo.environment["KORE_SNAPSHOT"]
    /// "x,y" clicks once; "x,y,2" double-clicks (inside Kore, like the single clicks).
    private static let clickList: [(NSPoint, Int)] = (ProcessInfo.processInfo.environment["KORE_CLICK"] ?? "")
        .split(separator: ";").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            guard xy.count >= 2 else { return nil }
            return (NSPoint(x: xy[0], y: xy[1]), xy.count > 2 ? Int(xy[2]) : 1)
        }
    private static var clicks: [NSPoint] { clickList.map(\.0) }

    /// KORE_HANGS: logs every main-thread stall over the threshold (with what was happening).
    @MainActor static func watchHangs() {
        guard let value = ProcessInfo.processInfo.environment["KORE_HANGS"] else { return }
        let threshold = (value == "1" ? 50 : Double(value) ?? 50) / 1000
        let start = Date()
        let tick = HangTick()
        // In the common modes, so it fires during tracking and live resize instead of reporting
        // those as stalls.
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = Date()
            tick.lock.lock()
            let gap = now.timeIntervalSince(tick.last)
            tick.last = now
            tick.stalledReported = false
            tick.lock.unlock()
            if gap > threshold {
                FileHandle.standardError.write(Data(String(format: "HANG %.0fms at %.2fs\n", gap * 1000, now.timeIntervalSince(start)).utf8))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hangWatchdog = watchStalls(tick)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            var focus = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            if let editor = event.window?.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField {
                focus += " field[\(field.placeholderString ?? "")]=\(editor.string) editable=\(editor.isEditable)/\(field.isEditable) enabled=\(field.isEnabled)"
            }
            FileHandle.standardError.write(Data(String(format: "EVENT %@ at %.2fs focus=%@\n", event.type == .keyDown ? "key" : "click", Date().timeIntervalSince(start), focus).utf8))
            if event.type == .keyDown, let window = event.window {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let after = (window.firstResponder as? NSTextView)?.string ?? "-"
                    FileHandle.standardError.write(Data("  after key: \(after) key=\(NSApp.keyWindow === window) active=\(NSApp.isActive)\n".utf8))
                }
            }
            return event
        }
    }

    /// KORE_DUMP=<path>: after KORE_DUMP_AFTER seconds (default 6), write the active chat's
    /// transcript entries as text, one per line, and quit (to compare replays between builds).
    @MainActor static func dumpIfRequested(_ chat: @escaping @MainActor () -> Chat?) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KORE_DUMP"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["KORE_DUMP_AFTER"] ?? "") ?? 6)) {
            let lines = (chat()?.transcript.entries ?? []).map { e in
                let files = e.attachments.map { "\($0.name):\($0.kind):\($0.thumbnail != nil)" }.joined(separator: ",")
                // Kinds keep their earlier names, so dumps compare across builds.
                let kind = e.kind == .answer ? "assistant" : "\(e.kind)"
                return [kind, e.toolName ?? "", e.text, e.result ?? "", "\(e.done)", "\(e.isError)", files, e.from ?? ""]
                    .joined(separator: " | ").replacingOccurrences(of: "\n", with: "⏎")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    static let timeReplay = ProcessInfo.processInfo.environment["KORE_TIME_REPLAY"] == "1" || DevBench.plan != nil

    nonisolated(unsafe) private static var hangWatchdog: DispatchSourceTimer?

    /// The main thread's last tick, shared with the watchdog off it.
    private final class HangTick: @unchecked Sendable {
        var last = Date()
        var stalledReported = false
        let lock = NSLock()
    }

    /// Off the main thread: a stall past 250ms says so while it's happening. Nonisolated, so its
    /// handler doesn't inherit the main actor and trap when it runs on the watchdog's queue.
    nonisolated private static func watchStalls(_ tick: HangTick) -> DispatchSourceTimer {
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.kore.hangs", qos: .utility))
        watchdog.schedule(deadline: .now(), repeating: 0.01)
        watchdog.setEventHandler {
            tick.lock.lock()
            let stalled = Date().timeIntervalSince(tick.last) > 0.25 && !tick.stalledReported
            if stalled { tick.stalledReported = true }
            tick.lock.unlock()
            if stalled { FileHandle.standardError.write(Data("STALL-START \(getpid())\n".utf8)) }
        }
        watchdog.resume()
        return watchdog
    }

    @MainActor static func logReplay(_ elapsed: Duration) {
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        if DevBench.isOn { DevBench.replayApplied(ms) }
        if ProcessInfo.processInfo.environment["KORE_TIME_REPLAY"] == "1" {
            FileHandle.standardError.write("REPLAY \(String(format: "%.1f", ms)) ms\n".data(using: .utf8)!)
        }
    }

    /// KORE_STOP_AFTER / KORE_ANSWER: drive a started chat without clicking.
    /// KORE_CONTEXT_CARD=1: the context wheel's card stays open.
    static let contextCard = ProcessInfo.processInfo.environment["KORE_CONTEXT_CARD"] == "1"

    @MainActor static func drive(_ chat: Chat) {
        let env = ProcessInfo.processInfo.environment
        if let parts = env["KORE_CONTEXT"]?.split(separator: ","), let used = parts.first.flatMap({ Int($0) }) {
            let window = parts.count > 1 ? Int(parts[1]) : nil
            let after = env["KORE_CONTEXT_AFTER"].flatMap(Double.init) ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                chat.context.apply(.contextUsage(ContextUsage(used: used, window: window, autoCompacts: true, at: .now)))
                if parts.count > 2 { chat.context.apply(.compactionStarted(auto: false)) }
            }
        }
        // The next message, 3s after a stop, to see a chat carry on after one.
        func sendAfterStop() {
            guard let text = env["KORE_SEND_AFTER_STOP"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                chat.draft = text
                chat.send()
            }
        }
        if let after = env["KORE_STOP_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                chat.stop()
                sendAfterStop()
            }
        }
        if let after = env["KORE_STOP_AGENT_AFTER"].flatMap(Double.init) {
            // As a running agent card's Stop does.
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                if let agent = chat.transcript.agentSummary.running.first { chat.stopAgent(agent.id) }
                sendAfterStop()
            }
        }
        // As the mode menu does, mid-session: "<id>@<seconds>[;<id>@<seconds>…]".
        for step in (env["KORE_SET_MODE"] ?? "").split(separator: ";") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let after = Double(parts[1]) else { continue }
            let id = String(parts[0])
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                if id == "plan-on" || id == "plan-off" { chat.setPlanMode(id == "plan-on") } else { chat.setMode(id) }
            }
        }
        let decision: Decision? =
            switch env["KORE_ANSWER"] {
            case "allow": .allow
            case "always": .allowAlways
            case "deny": .deny
            default: nil
            }
        guard let decision else { return }
        Task { @MainActor in
            while true {
                if let approval = chat.approvals.pending.first { chat.answer(approval, decision) }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    @MainActor static func captureIfRequested() {
        guard let output else { return }
        if let size = ProcessInfo.processInfo.environment["KORE_SIZE"]?.split(separator: ",").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?
                    .setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
        if let sweep = ProcessInfo.processInfo.environment["KORE_RESIZE_SWEEP"]?.split(separator: ",").compactMap({ Double($0) }),
            sweep.count >= 3
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + (sweep.count > 3 ? sweep[3] : 4)) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) })
                else { return }
                Task { @MainActor in
                    let started = Date()
                    var frames = 0
                    while true {
                        let t = Date().timeIntervalSince(started) / sweep[2]
                        if t >= 1 { break }
                        // There and back.
                        let phase = t < 0.5 ? t * 2 : (1 - t) * 2
                        var size = window.contentRect(forFrameRect: window.frame).size
                        size.width = (sweep[0] + (sweep[1] - sweep[0]) * phase).rounded()
                        window.setContentSize(size)
                        frames += 1
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    FileHandle.standardError.write(Data("SWEEP \(frames) frames in \(String(format: "%.2f", elapsed))s\n".utf8))
                }
            }
        }
        if ProcessInfo.processInfo.environment["KORE_FULLSCREEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.toggleFullScreen(nil)
            }
        }
        if let drag = ProcessInfo.processInfo.environment["KORE_DRAG"]?.split(separator: ",").compactMap({ Double($0) }),
            drag.count == 4
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + (clicks.isEmpty ? 2 : 2.5 + Double(clicks.count))) {
                post(drag: NSPoint(x: drag[0], y: drag[1]), by: CGVector(dx: drag[2], dy: drag[3]))
            }
        }
        let keys = (ProcessInfo.processInfo.environment["KORE_KEYS"] ?? "").split(separator: ";")
        for (index, key) in keys.enumerated() {
            // "cmd+shift+25": modifiers, then the virtual key code.
            var parts = key.split(separator: "+")
            guard let last = parts.popLast(), let code = CGKeyCode(last) else { continue }
            var flags: NSEvent.ModifierFlags = []
            for part in parts {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let start = 2.5 + Double(clicks.count) + (ProcessInfo.processInfo.environment["KORE_DRAG"] == nil ? 0 : 1.5)
            let modifiers = flags
            DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(index) * 0.5) {
                let flags = modifiers
                if ProcessInfo.processInfo.environment["KORE_REAL_KEYS"] == "1" {
                    // Through the window server: goes to whichever app is frontmost.
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                        event?.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                        event?.post(tap: .cghidEventTap)
                    }
                } else {
                    send(key: code, flags: flags)
                }
            }
        }
        if ProcessInfo.processInfo.environment["KORE_PASTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    for down in [true, false] {
                        let key = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)  // "v"
                        key?.flags = .maskCommand
                        key?.post(tap: .cghidEventTap)
                    }
                }
            }
        }
        let real = ProcessInfo.processInfo.environment["KORE_REAL_CLICK"] == "1"
        let clickStart = Double(ProcessInfo.processInfo.environment["KORE_CLICK_AFTER"] ?? "") ?? 2.5
        for (index, point) in clicks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + clickStart + Double(index)) {
                real ? post(click: point) : send(click: point, count: clickList[index].1)
            }
        }
        if let after = ProcessInfo.processInfo.environment["KORE_CLOSE_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }?.performClose(nil)
            }
        }
        let delay = Double(ProcessInfo.processInfo.environment["KORE_WAIT"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The folder window first, then any others (popovers) as <output>-1.png, -2, ...
            let windows = NSApp.windows.filter(\.isVisible).sorted { a, _ in a.styleMask.contains(.fullSizeContentView) }
            for (index, window) in windows.enumerated() {
                guard let frame = window.contentView?.superview,
                    let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                let path = index == 0 ? output : output.replacingOccurrences(of: ".png", with: "-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                // Where it sits in KORE_CLICK coordinates (from the folder window's top-left).
                let origin = windows[0].frame
                FileHandle.standardError.write(Data(
                    "WINDOW \(index): x \(window.frame.minX - origin.minX) y \(origin.maxY - window.frame.maxY) size \(window.frame.size)\n".utf8))
            }
            exit(0)
        }
    }

    /// A mouse click posted to the window server, exactly like the user's; restores the cursor.
    @MainActor private static func post(click point: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
            let screenHeight = NSScreen.screens.first?.frame.height
        else { return }
        // Only when needed: re-keying the window would close an open popover.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let target = CGPoint(x: window.frame.minX + point.x, y: screenHeight - (window.frame.maxY - point.y))
            let original = CGEvent(source: nil)?.location
            // Move there first, as a hand does, then press and release.
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let original { CGWarpMouseCursorPosition(original) }
                }
            }
        }
    }

    /// A real press-drag-release; reports how far the window moved.
    @MainActor private static func post(drag point: NSPoint, by delta: CGVector) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
            let screenHeight = NSScreen.screens.first?.frame.height
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let before = window.frame.origin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let start = CGPoint(x: window.frame.minX + point.x, y: screenHeight - (window.frame.maxY - point.y))
            // Spread over time so the app handles each event as a user's drag would.
            func post(_ type: CGEventType, _ p: CGPoint, after delay: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
            }
            post(.leftMouseDown, start, after: 0)
            for step in 1...10 {
                let p = CGPoint(x: start.x + delta.dx * Double(step) / 10, y: start.y + delta.dy * Double(step) / 10)
                post(.leftMouseDragged, p, after: 0.1 + Double(step) * 0.03)
            }
            post(.leftMouseUp, CGPoint(x: start.x + delta.dx, y: start.y + delta.dy), after: 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = window.frame.origin
                FileHandle.standardError.write(Data("DRAG moved window by (\(after.x - before.x), \(after.y - before.y))\n".utf8))
            }
        }
    }

    /// A key press delivered inside Kore (NSApp.sendEvent, so event monitors see it), aimed at
    /// the folder window. It can't reach another app, even if the user brings one to the front.
    @MainActor private static func send(key code: CGKeyCode, flags: NSEvent.ModifierFlags) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }) else { return }
        if !window.isKeyWindow { window.makeKey() }
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        // The shifted character for ⇧ (the others leave characters as typed).
        cgEvent?.flags = flags.contains(.shift) ? .maskShift : []
        let probe = cgEvent.flatMap(NSEvent.init(cgEvent:))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: probe?.characters ?? "",
                charactersIgnoringModifiers: probe?.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: code)
            {
                NSApp.sendEvent(event)
            }
        }
    }

    /// A mouse down/up delivered inside Kore (skips the window server).
    @MainActor private static func send(click point: NSPoint, count: Int = 1) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }) else { return }
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for (type, clickCount) in (1...max(count, 1)).flatMap({ n in [(NSEvent.EventType.leftMouseDown, n), (.leftMouseUp, n)] }) {
            if let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
            {
                // Through NSApp, so local event monitors (outside-click handling) see it too.
                NSApp.sendEvent(event)
            }
        }
    }

    /// KORE_EARLIER: drives the transcript's top for a snapshot (see the list above).
    @MainActor static func earlier(_ run: @escaping @MainActor (_ load: Bool) -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["KORE_EARLIER"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["KORE_EARLIER_AFTER"] ?? "") ?? 4)) {
            run(mode == "load")
        }
    }

    /// KORE_FORK: which user message to fork from, 1-based.
    static let forkMessage = ProcessInfo.processInfo.environment["KORE_FORK"].flatMap { Int($0) }
    static let forkSend = ProcessInfo.processInfo.environment["KORE_FORK_SEND"]
}
