import SwiftUI

/// Buttons in a row, right-aligned; stacked one per line when the row doesn't fit (a narrow
/// tile), so no label is ever clipped.
struct AdaptiveButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.md) {
                Spacer(minLength: 0)
                content
            }
            VStack(alignment: .trailing, spacing: Space.sm) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
