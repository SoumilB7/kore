import AppKit
import Foundation

/// `KORE_SCROLL_LOG=<path>`: every move of a transcript's scroll view, one line each, and the code
/// that made it, so a jump nobody asked for names its cause. Off (nothing built, nothing written)
/// without it. Lines: seconds since the first line, the event, then `key=value`s:
///
///   12.345 geo h=48210 dh=+312 off=40200 doff=+0 vis=777 in=3 follow=0 gest=0 anchor=answer-1a2b@-120
///   12.346 move why=paged to=40512
///   12.350 clip y=40512 dy=+312 doc=48210 in=3
///
/// `in` counts the reader's own inputs (`ScrollShift.readerInputs`): a `clip` line whose `dy` no
/// `move` line before it and no new input explain is SwiftUI's or AppKit's own.
@MainActor
package enum ScrollLog {
    static let path = ProcessInfo.processInfo.environment["KORE_SCROLL_LOG"].flatMap { $0.isEmpty ? nil : $0 }
    package static let on = path != nil
    private static var handle: FileHandle?
    private static var began: CFTimeInterval?
    private static var buffer = ""

    package static func write(_ event: String, _ fields: @autoclosure () -> String = "") {
        guard on else { return }
        let now = CACurrentMediaTime()
        let start = began ?? now
        began = start
        let text = fields()
        buffer += String(format: "%.3f ", now - start) + event + (text.isEmpty ? "" : " " + text) + "\n"
        if buffer.utf8.count > 16_384 { flush() } else { scheduleFlush() }
    }

    private static var flushScheduled = false

    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                flushScheduled = false
                flush()
            }
        }
    }

    static func flush() {
        guard on, !buffer.isEmpty, let path else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
        }
        handle?.write(Data(buffer.utf8))
        buffer = ""
    }

    /// A number as a log value: whole points.
    static func n(_ v: CGFloat) -> String { String(Int(v.rounded())) }
    /// A change, signed.
    static func d(_ v: CGFloat) -> String { (v >= 0 ? "+" : "") + String(Int(v.rounded())) }
}
