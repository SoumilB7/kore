import SwiftUI

/// KoreNet's line glyphs (korenet-first-connect.html, frame F): one hue, stroke 1.35 on the
/// 16-unit grid of the title row's icons, round caps. A box is two stacked units (not a cube, so
/// it never reads as a package); the network is three nodes on a triangle (not a globe or Wi-Fi
/// arcs, which already mean "internet").
struct NetGlyph: View {
    enum Kind: Sendable {
        case mac, box, phone, net, plus, more, external, chevron, close, copy
    }

    let kind: Kind
    var size: CGFloat = Size.Net.glyph

    var body: some View {
        let scale = size / 16
        ZStack {
            NetGlyphShape(kind: kind, part: .main).stroke(style: StrokeStyle(lineWidth: Self.width(kind) * scale, lineCap: .round, lineJoin: .round))
            if kind == .box {
                // The units' lights: a touch heavier than the outline.
                NetGlyphShape(kind: kind, part: .lights).stroke(style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func width(_ kind: Kind) -> CGFloat {
        switch kind {
        case .plus, .external, .chevron, .close: 1.4
        case .more: 2
        case .copy: 1.3
        default: 1.35
        }
    }
}

/// A glyph's path on the 16-unit grid, scaled into its frame.
struct NetGlyphShape: Shape {
    enum Part { case main, lights }
    let kind: NetGlyph.Kind
    var part: Part = .main

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch (kind, part) {
        case (.mac, _):
            p.addRoundedRect(in: CGRect(x: 3, y: 3.4, width: 10, height: 7.2), cornerSize: CGSize(width: 1.2, height: 1.2))
            p.move(to: CGPoint(x: 1.5, y: 12.7))
            p.addLine(to: CGPoint(x: 14.5, y: 12.7))
        case (.box, .main):
            p.addRoundedRect(in: CGRect(x: 2.5, y: 2.6, width: 11, height: 4.6), cornerSize: CGSize(width: 1.2, height: 1.2))
            p.addRoundedRect(in: CGRect(x: 2.5, y: 8.8, width: 11, height: 4.6), cornerSize: CGSize(width: 1.2, height: 1.2))
        case (.box, .lights):
            p.move(to: CGPoint(x: 5, y: 4.9))
            p.addLine(to: CGPoint(x: 5.4, y: 4.9))
            p.move(to: CGPoint(x: 5, y: 11.1))
            p.addLine(to: CGPoint(x: 5.4, y: 11.1))
        case (.phone, _):
            p.addRoundedRect(in: CGRect(x: 4.6, y: 1.6, width: 6.8, height: 12.8), cornerSize: CGSize(width: 1.7, height: 1.7))
            p.move(to: CGPoint(x: 7.3, y: 12.1))
            p.addLine(to: CGPoint(x: 8.7, y: 12.1))
        case (.net, _):
            for (x, y) in [(8, 3.4), (3.4, 12.3), (12.6, 12.3)] as [(CGFloat, CGFloat)] {
                p.addEllipse(in: CGRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4))
            }
            p.move(to: CGPoint(x: 7.2, y: 4.9))
            p.addLine(to: CGPoint(x: 4.2, y: 10.8))
            p.move(to: CGPoint(x: 8.8, y: 4.9))
            p.addLine(to: CGPoint(x: 11.8, y: 10.8))
            p.move(to: CGPoint(x: 5.1, y: 12.3))
            p.addLine(to: CGPoint(x: 10.9, y: 12.3))
        case (.plus, _):
            p.move(to: CGPoint(x: 8, y: 3.2))
            p.addLine(to: CGPoint(x: 8, y: 12.8))
            p.move(to: CGPoint(x: 3.2, y: 8))
            p.addLine(to: CGPoint(x: 12.8, y: 8))
        case (.more, _):
            for x in [3.6, 8, 12.4] as [CGFloat] {
                p.move(to: CGPoint(x: x, y: 8))
                p.addLine(to: CGPoint(x: x + 0.01, y: 8))
            }
        case (.external, _):
            p.move(to: CGPoint(x: 6, y: 3.6))
            p.addLine(to: CGPoint(x: 12.4, y: 3.6))
            p.addLine(to: CGPoint(x: 12.4, y: 10))
            p.move(to: CGPoint(x: 12.3, y: 3.7))
            p.addLine(to: CGPoint(x: 4, y: 12))
        case (.chevron, _):
            p.move(to: CGPoint(x: 6, y: 3.5))
            p.addLine(to: CGPoint(x: 10.5, y: 8))
            p.addLine(to: CGPoint(x: 6, y: 12.5))
        case (.close, _):
            p.move(to: CGPoint(x: 4.5, y: 4.5))
            p.addLine(to: CGPoint(x: 11.5, y: 11.5))
            p.move(to: CGPoint(x: 11.5, y: 4.5))
            p.addLine(to: CGPoint(x: 4.5, y: 11.5))
        case (.copy, _):
            p.addRoundedRect(in: CGRect(x: 5, y: 5, width: 8.5, height: 8.5), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.move(to: CGPoint(x: 3, y: 10.5))
            p.addLine(to: CGPoint(x: 3, y: 3.8))
            p.addQuadCurve(to: CGPoint(x: 3.8, y: 3), control: CGPoint(x: 3, y: 3))
            p.addLine(to: CGPoint(x: 10.5, y: 3))
        }
        let scale = min(rect.width, rect.height) / 16
        return p.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// The 6pt status dot, ringed in the colour of what it sits on (frame F): filled green for
/// connected, filled accent for needs you, hollow for not set up, needs allow or Tailscale off,
/// filled tertiary for offline.
struct NetDot: View {
    enum Fill: Equatable, Sendable { case connected, needsYou, hollow, offline }
    let fill: Fill
    /// What it sits on: its ring's colour (none in a row, where it stands alone).
    var on: Color?

    var body: some View {
        let size = Size.Net.dot
        ZStack {
            switch fill {
            case .connected: Circle().fill(Theme.Net.connected)
            case .needsYou: Circle().fill(Theme.Net.needsYou)
            case .offline: Circle().fill(Theme.Net.dim)
            case .hollow:
                Circle().fill(on ?? .clear)
                Circle().strokeBorder(Theme.Net.dim, lineWidth: Size.Net.hollow)
            }
        }
        .frame(width: size, height: size)
        .background {
            if let on { Circle().fill(on).frame(width: size + Size.Net.dotRing * 2, height: size + Size.Net.dotRing * 2) }
        }
        .accessibilityHidden(true)
    }
}

/// The spinner beside a waiting line: a ring with one lit quarter, turning once a second while
/// it's on screen (Reduce Motion: still).
struct NetSpinner: View {
    @StateObject private var turned = Local(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Net.spinnerTrack, lineWidth: Size.Net.spinnerLine)
            Circle().trim(from: 0, to: 0.25).stroke(Theme.secondary, style: StrokeStyle(lineWidth: Size.Net.spinnerLine, lineCap: .round))
                .rotationEffect(.degrees(turned.value ? 360 : 0))
        }
        .frame(width: Size.Net.spinner, height: Size.Net.spinner)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turned.value = true }
        }
        .accessibilityLabel(Text("Waiting"))
    }
}

/// The card's and the sheet's buttons (24pt): plain, the accent one (the default, with its ↩
/// hint), or a dimmed one that takes nothing.
struct NetButtonStyle: ButtonStyle {
    enum Look { case plain, go, dim, danger }
    var look: Look = .plain
    var height: CGFloat = Size.Net.button
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Net.button)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, look == .go ? Space.lg + 1 : Space.lg + 1)
            .frame(height: height)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
    }

    private var foreground: Color {
        switch look {
        case .go: Theme.Net.onAccent
        case .dim: Theme.tertiary
        case .danger: Theme.danger
        case .plain: isEnabled ? Theme.text : Theme.tertiary
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch look {
        case .go: pressed ? Theme.Blue.b400 : Theme.accent
        default: pressed ? Theme.surfaceRaised : Theme.surfaceHover
        }
    }
}
