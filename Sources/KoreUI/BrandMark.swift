import AppKit
import SwiftUI

/// Kore's K without its tile, for drawing on the app's own background: the stem a darker
/// shade behind, the crossing X a lighter one in front (Resources/AppIcon.svg has the tile).
struct BrandMark: View {
    var height: CGFloat = 56
    var monochrome = false

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(monochrome ? .template : .original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .foregroundStyle(Theme.secondary)
            .accessibilityLabel("Kore")
    }

    @MainActor private static let image: NSImage = {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.size = NSSize(width: 142, height: 202)
        return image
    }()

    // The glyph of Resources/AppIcon.svg, cropped to its own bounds.
    private static let svg = #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="57 27 142 202" width="142" height="202">
  <defs>
    <linearGradient id="front" gradientUnits="userSpaceOnUse" x1="84" y1="33.7" x2="220" y2="222.3">
      <stop offset="0" stop-color="#6AB1E7"/>
      <stop offset="1" stop-color="#3C97DD"/>
    </linearGradient>
    <linearGradient id="back" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#257DC1"/>
      <stop offset="1" stop-color="#1B6298"/>
    </linearGradient>
  </defs>
  <g transform="translate(-24 0)" stroke-linejoin="round" stroke-width="6">
    <rect x="116" y="30" width="24" height="196" rx="6" fill="url(#back)" stroke="#1B6298"/>
    <g fill="url(#front)" stroke="#3C97DD">
      <polygon points="84,147.96 220,33.72 220,67.72 84,181.96"/>
      <polygon points="84,74.04 220,188.28 220,222.28 84,108.04"/>
    </g>
  </g>
</svg>
"""#
}
