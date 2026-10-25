import AppKit
import SwiftUI

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

/// Kore's windows draw in sRGB: every colour Kore names is an sRGB hex, so nothing it draws
/// changes, and on a wide-gamut screen a layer holding more than one colour (a link, a code
/// span) is kept at 4 bytes a pixel instead of 8. Pictures in a P3 profile show clamped to sRGB.
enum WindowColor {
    static let space = NSColorSpace.sRGB

    static func prepare(_ window: NSWindow) {
        if window.colorSpace != space { window.colorSpace = space }
    }
}
