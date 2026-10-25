import AppKit
import KoreCore
import SwiftUI

// New tab's install flow (cli-install.html): a CLI that isn't on the Mac shows the not-installed
// mark in the provider bar; a click grows the bar upward into the install card, a progress line
// runs along its top edge while it installs, and "✓ … installed" folds back into the bar.

/// The not-installed mark (cli-missing-mark.html, option 1 "Arrow notch"): the logo dimmed in its
/// own colour with a ↓ cut into its bottom-right corner, turning accent while hovered. Drawn on a
/// 24-unit logo whose 28-unit box overhangs it, so the bar keeps its layout.
struct MissingLogo: View {
    let provider: Provider
    let size: CGFloat
    let hovered: Bool

    var body: some View {
        let unit = size / 24
        ProviderLogo(provider: provider, size: size)
            .opacity(Theme.missingLogo)
            .mask {
                Rectangle()
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .frame(width: 13.8 * unit, height: 13.8 * unit)
                            .offset(x: 15.5 * unit, y: 15.5 * unit)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .topLeading) {
                NotchArrow()
                    .stroke(hovered ? Theme.accent : Theme.secondary, style: StrokeStyle(lineWidth: 2.1 * unit, lineCap: .round, lineJoin: .round))
                    .frame(width: 28 * unit, height: 28 * unit)
            }
    }
}

/// The ↓ in the notch, in the mark's 28-unit box.
private struct NotchArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 28
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(22.4, 18.2))
        path.addLine(to: point(22.4, 26))
        path.move(to: point(19.2, 22.9))
        path.addLine(to: point(22.4, 26.1))
        path.addLine(to: point(25.6, 22.9))
        return path
    }
}

/// The card above the provider row: offer, installing, installed or failed.
struct InstallCard: View {
    let provider: Provider
    let card: CLIInstalls.Card

    var body: some View {
        let installs = CLIInstalls.shared
        let product = provider.usage.product
        let id = StoryID.NewTab.install
        VStack(alignment: .leading, spacing: Space.xxs) {
            switch card.phase {
            case .offer:
                title("\(product) isn't on this Mac")
                line("One click installs it with \(provider.install.maker)'s official installer.")
                HStack(spacing: Space.xl) {
                    InstallButton(provider: provider.id, methods: installs.methods)
                    InstallLink("Locate…", id.part(.locate)) { installs.locate() }
                    Spacer(minLength: Space.md)
                    InstallLink("Cancel", id.part(.cancel)) { installs.cancel() }
                }
                .padding(.top, Space.lg)
                Text(provider.install.source)
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .padding(.top, Space.lg)
            case .installing(let progress):
                title("Installing \(product)")
                HStack(spacing: Space.xl) {
                    line("\(progress.text) · you can keep using Kore")
                    Spacer(minLength: Space.md)
                    InstallLink("Cancel", id.part(.cancel)) { installs.cancel() }
                }
            case .installed:
                HStack(spacing: Space.sm) {
                    Image(systemName: "checkmark").foregroundStyle(Theme.success)
                    Text("\(product) installed").foregroundStyle(Theme.text)
                }
                .font(TextStyle.title)
                .storyMark(id.part(.done))
            case .failed(let reason):
                title("Couldn't install \(product)", Theme.danger)
                line(reason.text)
                HStack(spacing: Space.xl) {
                    Button("Try again") { installs.retry() }
                        .buttonStyle(AccentButtonStyle())
                        .storyID(id.part(.retry), press: { installs.retry() })
                    InstallLink("Copy command", id.part(.copy)) { installs.copyCommand() }
                    Spacer(minLength: Space.md)
                    InstallLink("Cancel", id.part(.cancel)) { installs.cancel() }
                }
                .padding(.top, Space.lg)
            }
        }
        .padding(.horizontal, Space.xxxl)
        .padding(.top, Space.xxxl)
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .storyID(id)
    }

    private func title(_ text: String, _ colour: Color = Theme.text) -> some View {
        Text(text).font(TextStyle.title).foregroundStyle(colour)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(TextStyle.body).foregroundStyle(Theme.secondary).lineLimit(1)
    }
}

/// The progress line along the bar's top edge, inset to clear its rounded corners.
struct InstallProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - Radius.panel * 2)
            Capsule()
                .fill(Theme.accent)
                .frame(width: width * min(max(fraction, 0), 1), height: Stroke.quote)
                .offset(x: Radius.panel, y: -Stroke.hairline)
                .animation(Motion.progress, value: fraction)
        }
        .frame(height: Stroke.quote)
        .allowsHitTesting(false)
        .storyMark(StoryID.NewTab.install.part(.working))
    }
}

/// "Install ⌄": Install runs the official installer; ⌄, shown only when the Mac has Homebrew or
/// npm, lists the ways it has (a Kore popup).
private struct InstallButton: View {
    let provider: String
    let methods: [CLIInstaller.Method]
    @StateObject private var anchor = Held(MenuAnchor())

    var body: some View {
        let installs = CLIInstalls.shared
        let id = StoryID.NewTab.install
        HStack(spacing: 0) {
            Button("Install") { installs.install(.official) }
                .buttonStyle(.plain)
                .padding(.leading, Space.xl)
                .padding(.trailing, methods.count > 1 ? Space.md : Space.xl)
                .storyID(id.part(.install), press: { installs.install(.official) })
            if methods.count > 1 {
                Rectangle().fill(Theme.onAccentRule).frame(width: Stroke.hairline).padding(.vertical, Space.xs)
                Button {
                    showMenu()
                } label: {
                    Image(systemName: "chevron.down").font(Chrome.captionMedium)
                        .padding(.horizontal, Space.md)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(AnchorView(anchor: anchor.value))
                .storyID(id.part(.method))
            }
        }
        .font(TextStyle.labelStrong)
        .foregroundStyle(Theme.background)
        .frame(height: Layout.Options.row - Space.xs)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Radius.chip))
        .fixedSize()
    }

    /// The ways, opening upward from the button.
    private func showMenu() {
        guard let view = anchor.value.view, let window = view.window else { return }
        let installs = CLIInstalls.shared
        let items = methods.map { method in
            OptionItem(
                method.title, checked: method == .official,
                key: method == .official ? "Recommended" : CLIInstaller.command(method, for: provider)
            ) { installs.install(method) }
        }
        let height = CGFloat(items.count) * Layout.Options.row + Space.xs * 2
        let top = view.convert(CGPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY), to: nil)
        OptionsMenu.shared.show(items, at: CGPoint(x: top.x - Layout.Options.width / 2, y: top.y + height + Space.xs), in: window, source: "install")
    }

    private final class MenuAnchor { weak var view: NSView? }

    private struct AnchorView: NSViewRepresentable {
        let anchor: MenuAnchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}

/// A quiet underlined text button (Locate…, Cancel, Copy command).
private struct InstallLink: View {
    let title: String
    let id: StoryID
    let action: @MainActor () -> Void
    @StateObject private var hovered = Local(false)

    init(_ title: String, _ id: StoryID, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(TextStyle.body)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .underline(color: Theme.border)
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .storyID(id, press: action)
    }
}

/// The card's one strong action: accent fill, dark words.
private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TextStyle.labelStrong)
            .foregroundStyle(Theme.background)
            .padding(.horizontal, Space.xl)
            .frame(height: Layout.Options.row - Space.xs)
            .background(configuration.isPressed ? Theme.accentLine : Theme.accent, in: RoundedRectangle(cornerRadius: Radius.chip))
    }
}
