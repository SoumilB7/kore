import AppKit
import SwiftUI

struct PlanChip: View {
    let mode: ModeOption
    let turnOff: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: turnOff) {
            HStack(spacing: Space.sm) {
                if hovered.value {
                    Image(systemName: "xmark.circle.fill").font(TextStyle.label)
                } else {
                    ModeIcon(mode: mode)
                }
                Text("Plan").font(TextStyle.labelMedium)
            }
            .foregroundStyle(Rung.plan.color)
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Turn off Plan mode")
    }
}

/// The CLI's own remote control, on: the bar's one mark of it, beside the mode. Its tooltip is
/// its one line ("Remote control · claude CLI · claude.ai/code"); a click turns it off.
struct RemoteChip: View {
    let remote: RemoteControl
    let cli: String
    let turnOff: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: turnOff) {
            HStack(spacing: Space.sm) {
                Image(systemName: hovered.value ? "xmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .font(TextStyle.label)
                Text("Remote").font(TextStyle.labelMedium)
            }
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered.value = $0 }
        .help(remote.line(cli: cli))
        .accessibilityLabel(Text(remote.line(cli: cli)))
    }

    /// Lit while a remote side can reach the chat, quiet while it links, a warning when it can't.
    private var color: Color {
        switch remote.state {
        case .connected: Theme.accent
        case .connecting: Theme.secondary
        case .failed: Theme.warning
        }
    }
}

// MARK: - Attachments

/// An attached image or video (thumbnail, click to view; a video's first frame, marked) or file
/// (icon + name); removable while still in the composer. Selected with the whole draft (⌘A), it takes the text selection's colour.
struct AttachmentChip: View {
    let attachment: Attachment
    var selected = false
    /// The composer has focus: the selection's active colour, else its inactive one.
    var focused = true
    var open: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        Group {
            if let thumbnail = attachment.thumbnail ?? attachment.poster?.image {
                Button {
                    open?()
                } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Size.thumb, height: Size.thumb)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: Radius.chip)
                                    .fill(Theme.Selection.imageWash(focused: focused))
                                    .strokeBorder(Theme.Selection.chip(focused: focused), lineWidth: Stroke.emphasis)
                            } else {
                                RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if attachment.poster?.video == true {
                                Image(systemName: "play.circle.fill")
                                    .font(TextStyle.label)
                                    .foregroundStyle(Theme.text, Theme.background)
                                    .padding(Space.xs)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(attachment.name)
            } else {
                HStack(spacing: Space.sm) {
                    Image(systemName: icon)
                        .font(TextStyle.label)
                        .foregroundStyle(Theme.secondary)
                    Text(attachment.name)
                        .font(TextStyle.label)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: Size.chipNameMax, alignment: .leading)
                }
                .padding(.horizontal, Space.lg)
                .frame(height: Size.chip)
                .background(
                    selected ? Theme.Selection.chip(focused: focused) : Theme.surfaceHover,
                    in: RoundedRectangle(cornerRadius: Radius.chip))
                .help(attachment.url?.path ?? attachment.name)
            }
        }
        .task { attachment.poster?.make() }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Glyph.remove)
                        .foregroundStyle(Theme.text, Theme.surfaceHover)
                        .hitTarget(Size.chipBadgeReach)
                }
                .buttonStyle(.plain)
                .hitTargetRoom(Size.chipBadgeReach)
                .offset(x: Size.chipBadge.width, y: Size.chipBadge.height)
                .help("Remove")
            }
        }
    }

    private var icon: String {
        switch attachment.kind {
        case .image: "photo"
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .other: attachment.url?.hasDirectoryPath == true ? "folder" : "doc"
        }
    }
}

/// Hands over the hosting NSWindow, so key handling can be limited to this window.
