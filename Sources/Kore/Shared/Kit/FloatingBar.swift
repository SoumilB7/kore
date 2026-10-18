import SwiftUI

/// The bottom-centre toolbar of a modal (ui-principles): one panel holding tool groups.
struct FloatingBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Space.xxs) { content }
            .padding(Inset.floatingBar)
            .panel(.panel)
    }
}

/// A thin vertical rule between tool groups.
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border)
            .frame(width: Size.divider.width, height: Size.divider.height)
            .padding(.horizontal, Space.sm)
    }
}
