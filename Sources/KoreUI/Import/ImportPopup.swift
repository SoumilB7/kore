import KoreCore
import SwiftUI

/// The import picker (chat-handoff.html §2 A), in the composer popups' slot and frame: a quiet
/// search past eight chats, the chats (logo, title, size, age; seven before it scrolls), then
/// one footer line with Choose file… and Import. Picking a row fills the line; only the footer
/// changes, and nothing moves. ↑ ↓ move a highlight over the chats and Return picks it. Esc, a
/// click outside or typing in the composer closes it, and Return never imports.
struct ImportPopup: View {
    let chat: Chat
    let state: ImportState
    let choose: @MainActor @Sendable () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        ComposerPopup(
            chat: chat, id: StoryID.Composer.importer, isOpen: { state.isOpen }, stepBack: { false }, close: { state.close() },
            editing: { state.searching }, keys: listKey
        ) {
            VStack(alignment: .leading, spacing: Space.sm) {
                if state.rows.count > ImportState.searchFrom { search }
                list
                footer
            }
        }
    }

    /// ↑ ↓ and Return for the list, the search field focused or not.
    private func listKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125, 126:
            state.moveCursor(event.keyCode == 125 ? 1 : -1)
            PointerGate.keyed()
            return true
        case 36, 76: return state.pickCursor()
        default: return false
        }
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField("Search", text: Binding(get: { state.query }, set: { state.query = $0 }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .storyID(StoryID.Composer.importer.part(.field))
        }
        .font(Chrome.label)
        .padding(.horizontal, Space.sm)
        .frame(height: Size.importLine)
        .onAppear { searchFocused = true }
        .onChange(of: searchFocused, initial: true) { _, focused in state.searching = focused }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let rows = state.shown
        if rows.isEmpty {
            Text(state.query.isEmpty ? "No other chats in this folder" : "No chats match")
                .font(TextStyle.caption)
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, Space.md)
                .frame(height: Size.importRow)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ImportRow(row: row, folder: chat.folder, selected: row.id == state.picked, lit: row.id == state.cursor) {
                            state.pick(row)
                        }
                        .highlightRow(StoryID.Composer.importRow(row.id), lit: row.id == state.cursor, selects: false) {
                            state.cursor = row.id
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: Size.importRow * CGFloat(min(rows.count, Size.importRowsShown)))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            line.frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose file…", action: choose)
                .smallButton()
                .storyID(StoryID.Composer.importer.part(.choose), press: choose)
                .tabStop(StoryID.Composer.importer.part(.choose), action: choose)
            Button("Import") { state.importPicked() }
                .smallButton(prominent: true)
                .storyID(StoryID.Composer.importer.part(.add), press: { [state] in if state.canImport { state.importPicked() } })
                .tabStop(StoryID.Composer.importer.part(.add)) { state.importPicked() }
                .disabled(!state.canImport)
        }
        .frame(height: Size.importRow)
    }

    @ViewBuilder private var line: some View {
        switch state.line {
        case .empty:
            Text(" ").font(TextStyle.caption)
        case .counting:
            SpinningArc().frame(width: Size.importSpinner, height: Size.importSpinner)
        case .ready(let preview):
            ready(preview)
        case .notImportable(let why):
            caption("Not a chat Kore can import", Theme.tertiary).help(why)
        case .sourceBusy:
            caption("Still running in its tab.", Theme.secondary)
        case .signedOut(let product):
            HStack(spacing: Space.md) {
                caption("\(product) isn't signed in.", Theme.secondary)
                Button("Sign in") { chat.signInAgain() }
                    .smallButton()
                    .storyID(StoryID.Composer.importer.part(.signIn), press: { chat.signInAgain() })
            }
        case .importing(let turns):
            HStack(spacing: Space.sm) {
                SpinningArc().frame(width: Size.importSpinner, height: Size.importSpinner)
                caption("Importing \(turns == 1 ? "1 turn" : "\(turns) turns")…", Theme.secondary)
            }
        case .failed(let why):
            HStack(spacing: Space.md) {
                caption("Couldn't import: \(why)", Theme.danger)
                Button("Try again") { state.retry() }
                    .smallButton()
                    .storyID(StoryID.Composer.importer.part(.reload), press: { state.retry() })
            }
        }
    }

    /// "23 turns · ~84k tokens · sent to OpenAI": the count's help says what goes at each level,
    /// the company's what leaves.
    private func ready(_ preview: HandoffPreview) -> some View {
        HStack(spacing: 0) {
            caption(ImportState.count(preview), Theme.secondary).help(ImportState.breakdown(preview))
            caption(" · " + ImportState.tokens(preview), Theme.secondary)
            if let company = ImportState.company(preview, into: chat) {
                caption(" · ", Theme.secondary)
                caption("sent to \(company)", Theme.secondary)
                    .help("Everything carried goes to \(company)'s model, including anything pasted into that chat.")
            }
        }
    }

    private func caption(_ text: String, _ color: Color) -> some View {
        Text(text).font(TextStyle.caption).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
    }
}

/// One chat in the picker: its source's logo, its title, then size and age in tertiary (a
/// spinner in place of the age while it runs in another tab). Picked, the row's selection;
/// under the pointer or the keys, its hover.
private struct ImportRow: View {
    let row: ImportState.Row
    let folder: URL
    let selected: Bool
    let lit: Bool
    let pick: @MainActor @Sendable () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Space.md) {
                if let provider = row.agent.flatMap(Registry.provider) {
                    ProviderLogo(provider: provider, size: Size.logoRow)
                } else {
                    Image(systemName: "doc").font(TextStyle.caption).foregroundStyle(Theme.tertiary)
                }
                Text(row.title)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.md)
                Group {
                    Text(row.size)
                    if row.running {
                        SpinningArc().frame(width: Size.importSpinner, height: Size.importSpinner)
                    } else if let updated = row.updated {
                        Text(updated.historyAge)
                    }
                }
                .font(TextStyle.caption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .fixedSize()
            }
            .padding(.horizontal, Space.md)
            .frame(height: Size.importRow)
            .background(
                selected ? Theme.Row.selected(.surface) : lit ? Theme.Row.hover(.surface) : .clear,
                in: RoundedRectangle(cornerRadius: Radius.chip)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(row.folder.map { $0 == folder.path ? row.title : "\(row.title)\n\($0)" } ?? row.title)
        .storyID(StoryID.Composer.importRow(row.id), press: pick)
    }
}
