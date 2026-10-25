import AppKit
import UniformTypeIdentifiers

/// A whole composer draft on a pasteboard (⌘A ⌘C): its text, its command and its attachments,
/// in their order, so ⌘V in another chat's composer puts it back as it was.
///
/// The board holds one item with Kore's own type and the text, then one item per attachment
/// with its file URL, and an image's own bytes under the image's type, so another app pastes
/// the text, the files or the pictures. The text comes first, where an app reading only text
/// looks; in Kore the chips sit above the text whatever the order.
struct DraftClipboard: Codable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        let name: String
        /// An image's file as it is on disk, byte for byte (its EXIF orientation with it): put
        /// back when the file has gone (a pasted image's temp file, cleaned up).
        let image: Data?
    }

    /// Whose draft it was: a command goes back to the chip only where it means the same.
    let provider: String
    let text: String
    let command: ChatDraft.Command?
    let files: [File]

    static let type = NSPasteboard.PasteboardType("dev.kore.composer-draft")
    /// An image bigger than this travels by its path alone.
    static let maxImageBytes = 32_000_000

    /// The clipboard; a storyline's own board in storylines, so the owner's is never touched.
    @MainActor static var pasteboard: NSPasteboard {
        StoryHost.installed ? NSPasteboard(name: .init("kore-storylines")) : .general
    }

    init(provider: String, text: String, command: ChatDraft.Command?, files: [File]) {
        self.provider = provider
        self.text = text
        self.command = command
        self.files = files
    }

    init(provider: String, text: String, command: SlashCommand?, attachments: [Attachment]) {
        let files = attachments.compactMap { attachment -> File? in
            guard let url = attachment.url else { return nil }
            var image: Data?
            if attachment.kind == .image, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= Self.maxImageBytes
            {
                image = try? Data(contentsOf: url)
            }
            return File(path: url.path, name: attachment.name, image: image)
        }
        self.init(provider: provider, text: text, command: command.map(ChatDraft.Command.init), files: files)
    }

    /// The draft as one text, the command first, as it would be sent.
    var plainText: String {
        guard let command, command.kind == .command else { return text }
        return text.isEmpty ? "/\(command.name)" : "/\(command.name) \(text)"
    }

    func write(to board: NSPasteboard) {
        guard let data = try? PropertyListEncoder.binary.encode(self) else { return }
        let draft = NSPasteboardItem()
        draft.setData(data, forType: Self.type)
        let plain = plainText
        if !plain.isEmpty { draft.setString(plain, forType: .string) }
        let items = [draft] + files.map { file in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: file.path).absoluteString, forType: .fileURL)
            if let image = file.image, let type = UTType(filenameExtension: (file.name as NSString).pathExtension) {
                item.setData(image, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            return item
        }
        board.clearContents()
        board.writeObjects(items)
    }

    static func read(from board: NSPasteboard) -> DraftClipboard? {
        guard board.availableType(from: [type]) != nil,
            let data = board.pasteboardItems?.lazy.compactMap({ $0.data(forType: type) }).first
        else { return nil }
        return try? PropertyListDecoder().decode(DraftClipboard.self, from: data)
    }

    static func isOn(_ board: NSPasteboard) -> Bool { board.availableType(from: [type]) != nil }

    /// The files to attach, in their order: each where it is, as Finder's copy would give it;
    /// an image whose file has gone, its bytes in a new file of the same name.
    func urls() -> [URL] {
        files.compactMap { file in
            var folder: ObjCBool = false
            // A folder keeps its trailing slash: its chip shows it as a folder.
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &folder) {
                return URL(fileURLWithPath: file.path, isDirectory: folder.boolValue)
            }
            let url = URL(fileURLWithPath: file.path)
            guard let image = file.image else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Kore", isDirectory: true)
                .appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(file.name.isEmpty ? url.lastPathComponent : file.name)
            return (try? image.write(to: copy)) != nil ? copy : nil
        }
    }
}

extension PropertyListEncoder {
    fileprivate static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
