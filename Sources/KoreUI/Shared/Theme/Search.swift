import SwiftUI

// The sidebar's Search (phase 10 look §3).

extension Size {
    @MainActor static var searchField: CGFloat { Zoom.pt(28) }
    @MainActor static var filterField: CGFloat { Zoom.pt(26) }
}

extension Layout {
    enum Search {
        /// Files after this many start closed.
        static let openFiles = 20
        /// Characters kept before a match in a result line.
        static let leadIn = 24
    }
}
