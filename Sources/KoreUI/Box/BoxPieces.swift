import HostClient
import SwiftUI

/// What the Boxes panel and the box popup share: a box's one line with its action, and the Add a
/// box… field.

/// A box's one line, and its action after a dot ("Stopped on mybox · Start").
struct BoxNoteLine: View {
    let note: BoxList.Note
    let alias: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(note.line).foregroundStyle(Theme.tertiary).lineLimit(2)
            if let action = note.action {
                Text("·").foregroundStyle(Theme.tertiary)
                Button(action.title) { Task { await BoxList.shared.act(action, on: alias) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
        }
        .font(Chrome.caption)
    }
}

/// The SSH alias field of Add a box…: Return adds what's typed when it's an alias
/// (`BoxList.alias(_:)`), Esc gives up.
struct BoxAliasField: View {
    @Binding var text: String
    let add: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("SSH alias").foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Chrome.label)
            .focused($focused)
            .fieldWell(focused: focused)
            .onSubmit { if let alias = BoxList.alias(text) { add(alias) } }
            .onExitCommand(perform: cancel)
            .onAppear { focused = true }
    }
}
