import SwiftUI

/// A path worked out from the view's size, to fill or stroke as a plain shape. No SwiftUI `Canvas`
/// in Kore: the first one that draws costs the process tens of MB of graphics memory.
struct SizedPath: Shape {
    let make: @Sendable (CGSize) -> Path

    init(_ make: @escaping @Sendable (CGSize) -> Path) { self.make = make }

    func path(in rect: CGRect) -> Path { make(rect.size) }
}
