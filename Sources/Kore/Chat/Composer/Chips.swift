import AppKit
import SwiftUI

struct PlanChip: View {
    let turnOff: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: turnOff) {
            HStack(spacing: 5) {
                if hovered.value {
                    Image(systemName: "xmark.circle.fill").font(.kore(12))
                } else {
                    ModeIcon(mode: Provider.codexPlan)
                }
                Text("Plan").font(.kore(12, .medium))
            }
            .foregroundStyle(ModeOption.Rung.plan.color)
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
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(attachment.name)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.kore(12))
                        .foregroundStyle(Theme.secondary)
                    Text(attachment.name)
                        .font(.kore(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 7))
                .help(attachment.url?.path ?? attachment.name)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text, Theme.surfaceHover)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
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
