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

// MARK: - Attachments

/// An attached image (thumbnail, click to view) or file (icon + name); removable while still
/// in the composer.
struct AttachmentChip: View {
    let attachment: Attachment
    var open: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        Group {
            if let thumbnail = attachment.thumbnail {
                Button {
                    open?()
                } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Size.thumb, height: Size.thumb)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                        .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border))
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
                .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.chip))
                .help(attachment.url?.path ?? attachment.name)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Glyph.remove)
                        .foregroundStyle(Theme.text, Theme.surfaceHover)
                }
                .buttonStyle(.plain)
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
