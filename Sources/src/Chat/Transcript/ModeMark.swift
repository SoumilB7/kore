import Foundation

/// A permission mode as the transcript marks it (look.md §8): its label, icon and rung,
/// copied from the provider's `ModeOption` when the change happened.
package struct ModeMark: Equatable, Sendable {
    package let id: String
    package let label: String
    package let svg: String
    package let iconSize: CGFloat
    /// nil for a neutral mode.
    package let rung: Rung?

    package init(_ option: ModeOption) {
        id = option.id
        label = option.label
        svg = option.icon
        iconSize = option.iconSize
        rung = option.rung
    }
}
