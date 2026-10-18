import AppKit
import SwiftUI

// The transcript's one text selection (z-docs/research/transcript-selection.md): the system's
// selection colours, as a dark window shows them, whatever the system appearance.

extension Theme {
    enum Selection {
        /// The selection while the transcript has focus in the key window.
        static let active = Color(nsColor: dark { .selectedTextBackgroundColor })
        /// The selection while focus is elsewhere (the composer, another window).
        static let inactive = Color(nsColor: dark { .unemphasizedSelectedTextBackgroundColor })

        /// A colour that resolves as the dark appearance shows it, each time it's drawn, so a
        /// change of the system's highlight colour comes through.
        private static func dark(_ color: @escaping @Sendable () -> NSColor) -> NSColor {
            NSColor(name: nil) { _ in
                var resolved = color()
                NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                    resolved = color().usingColorSpace(.sRGB) ?? color()
                }
                return resolved
            }
        }
    }
}

extension Layout {
    enum Selection {
        /// How far a press moves before it becomes a selection drag.
        static let dragStart: CGFloat = 3
        /// Scrolling while the pointer is held past the transcript's edge: a step this often,
        /// as many points as the pointer is past the edge, within these bounds.
        static let autoscrollInterval: TimeInterval = 1.0 / 60
        static let autoscrollMin: CGFloat = 2
        static let autoscrollMax: CGFloat = 40
        /// Texts kept laid out for hit-testing and the highlight.
        static let layoutCache = 96
        /// Rows off screen whose texts' places are kept (a lazy stack shows a kept row again
        /// without laying it out).
        static let offscreenRows = 200
    }
}
