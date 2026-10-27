import SwiftUI

/// The @ menu: what matches the typed "@word", grouped by kind, the slash menu's look and keys
/// (↑↓ move, Return/Tab accept, handled by the composer). One highlight: the pointer moves the
/// selection, as in a menu.
struct AtMenu: View {
    let items: [AtItem]
    let selected: Int
    let select: (Int) -> Void
    let accept: (AtItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].kind != item.kind {
                            Text(item.kind.title)
                                .font(TextStyle.caption)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, Space.md)
                                .padding(.top, index == 0 ? 0 : Space.sm)
                        }
                        Button { accept(item) } label: { row(item, lit: index == selected) }
                            .buttonStyle(.plain)
                            .highlightRow(StoryID.Composer.mention(item.id), lit: index == selected) { select(index) }
                            .storyID(StoryID.Composer.mention(item.id), press: { accept(item) })
                            .id(item.id)
                    }
                }
                .padding(Space.xs)
            }
            .onChange(of: selected) { if items.indices.contains(selected) { proxy.scrollTo(items[selected].id) } }
        }
        .frame(maxHeight: Size.menuMax)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
    }

    private func row(_ item: AtItem, lit: Bool) -> some View {
        HStack(spacing: Space.md) {
            glyph(item)
            Text(item.label)
                .font(TextStyle.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Space.xl)
        }
        .padding(Inset.row)
        .hoverFill(lit, Theme.Row.selected(.surface))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func glyph(_ item: AtItem) -> some View {
        switch item.kind {
        case .file: FileIconView(name: item.label)
        case .folder: symbol("folder")
        case .model: symbol("cpu")
        case .skill: symbol("sparkles")
        case .tab: symbol("rectangle.on.rectangle")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(Chrome.glyphTreeIcon)
            .foregroundStyle(Theme.secondary)
            .frame(width: Size.Tree.icon, height: Size.Tree.icon)
    }
}
