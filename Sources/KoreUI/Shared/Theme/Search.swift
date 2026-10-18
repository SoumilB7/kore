import SwiftUI

// The sidebar's Search (phase 10 look §3).

extension Size {
    static let searchField: CGFloat = 28
    static let filterField: CGFloat = 26
}

extension Layout {
    enum Search {
        /// Files after this many start closed.
        static let openFiles = 20
        /// Characters kept before a match in a result line.
        static let leadIn = 24
    }
}
