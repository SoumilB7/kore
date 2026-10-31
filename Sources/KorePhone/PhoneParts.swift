import AppKit
import CoreImage.CIFilterBuiltins
import KoreRemote
import KoreUI
import SwiftUI

/// One paired phone: connected (full access or alerts only) or when it was last seen.
struct PhoneRow: View {
    let row: PhoneModel.Row
    let host: RemoteHost
    @StateObject private var hovered = Box(false)

    var body: some View {
        HStack(spacing: ModuleStyle.md) {
            Image(systemName: "iphone").foregroundStyle(row.connected ? ModuleStyle.text : ModuleStyle.tertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(ModuleStyle.bodyMedium).foregroundStyle(ModuleStyle.text)
                Text(status).font(ModuleStyle.caption).foregroundStyle(ModuleStyle.tertiary)
            }
            Spacer()
            if row.connected {
                Button("Disconnect") { host.service.disconnect(row.id) }.moduleButton()
            }
            Button("Remove") { host.service.remove(row.id) }.moduleButton(danger: true)
        }
        .moduleHover(hovered.value)
        .onHover { hovered.value = $0 }
        .moduleStoryID(PhoneUI.rowID(row.id))
    }

    private var status: String {
        guard row.connected else { return "Last seen \(row.lastSeen.formatted(.relative(presentation: .named)))" }
        return row.access == .full ? "Connected · open, full access" : "Connected · alerts only"
    }
}

/// The QR for a phone to scan: 60 s, once, kept out of screen sharing while it shows.
struct PairCode: View {
    let text: String
    let until: Date
    let cancel: @MainActor () -> Void

    var body: some View {
        VStack(spacing: ModuleStyle.sm) {
            Text("Scan with the Kore app").font(ModuleStyle.labelMedium).foregroundStyle(ModuleStyle.secondary)
            if let image = Self.image(text) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: ModuleStyle.code2D, height: ModuleStyle.code2D)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(until.timeIntervalSince(context.date)))
                Text(left > 0 ? "Works once · ends in 0:\(String(format: "%02d", left))" : "Ended")
                    .font(ModuleStyle.caption).foregroundStyle(ModuleStyle.tertiary)
            }
            Button("Cancel") { cancel() }.moduleButton().moduleStoryID(PhoneUI.cancelID)
        }
        .frame(maxWidth: .infinity)
        .onAppear { Self.hideFromSharing(true) }
        .onDisappear { Self.hideFromSharing(false) }
    }

    /// Screen sharing and recording see a blank window while the code shows (best effort).
    static func hideFromSharing(_ hide: Bool) {
        for window in NSApp.windows where window.isVisible { window.sharingType = hide ? .none : .readOnly }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A view's own value (`@State` needs the macro plugins this build doesn't have).
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// "What the relay sees": one table, what it can and can't know.
struct RelaySees: View {
    let back: @MainActor () -> Void

    static let rows: [(String, String)] = [
        ("Sees", "The Mac's and the phone's IP addresses · when each is connected · how big each message is · a random mailbox id"),
        ("Never sees", "Messages, chats, files, folder names, account emails, keys: everything is encrypted between the phone and the Mac"),
        ("Stores", "Nothing: no logs of messages, no accounts; the mailbox goes when Kore's Phone goes off or quits"),
        ("If it's hostile", "It can drop or delay messages, never read, change or invent them: a forged one ends the session"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ModuleStyle.sm) {
            HStack {
                Text("What the relay sees").font(ModuleStyle.labelMedium).foregroundStyle(ModuleStyle.secondary)
                Spacer()
                Button("Back") { back() }.buttonStyle(.link).font(ModuleStyle.caption)
            }
            ForEach(Self.rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: ModuleStyle.md) {
                    Text(row.0).font(ModuleStyle.caption).foregroundStyle(ModuleStyle.tertiary)
                    Text(row.1).font(ModuleStyle.label).foregroundStyle(ModuleStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
