import src
import SwiftUI

/// The look of each step on the mode ladder (`Rung`): how strongly the composer outline signals
/// a mode.
extension Rung {
    var color: Color {
        switch self {
        case .plan: Theme.Blue.b200
        case .edits: Theme.Blue.b400
        case .auto: Theme.Blue.b300
        case .danger: Theme.danger
        }
    }

    /// Outline opacity when focused (×0.65 unfocused).
    var opacity: Double {
        switch self {
        case .plan: 0.55
        case .edits: 0.85
        case .auto: 1
        case .danger: 0.9
        }
    }

    var width: CGFloat {
        switch self {
        case .plan, .edits: 1
        case .auto, .danger: 1.5
        }
    }
}
