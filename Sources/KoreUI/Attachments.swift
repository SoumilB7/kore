import AppKit
import KoreCore
import UniformTypeIdentifiers

/// A file attached to a message: picked with +, pasted, or dropped.
package struct Attachment: Identifiable {
    package enum Kind: Sendable { case image, text, pdf, other }

    package let id = UUID()
    let name: String
    let kind: Kind
    /// Where it lives on disk (pasted images are saved to a temp file); nil when only known
    /// from a transcript.
    let url: URL?
    let thumbnail: NSImage?

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        kind = Attachments.kind(of: url)
        thumbnail = kind == .image ? NSImage(contentsOf: url) : nil
    }

    init(name: String, kind: Kind, thumbnail: NSImage? = nil) {
        url = nil
        self.name = name
        self.kind = kind
        self.thumbnail = thumbnail
    }
}

/// How attachments become message content, mirroring each CLI's own client:
/// - Claude (as its VS Code extension): images as base64 image blocks, text files as text
///   document blocks, PDFs as base64 document blocks; anything else as an @path reference.
/// - Codex: images as `localImage`, everything else as a `mention` it reads itself.
package enum Attachments {
    // MARK: Classification (the Claude extension's lists)

    private static let textMIMETypes: Set<String> = [
        "application/json", "application/xml", "application/javascript", "application/typescript",
        "application/x-javascript", "application/x-typescript", "application/x-yaml", "application/yaml",
        "application/x-sh", "application/x-shellscript", "application/sql", "application/graphql",
        "application/toml", "application/x-toml",
    ]

    private static let textExtensions: Set<String> = [
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "config", "env", "properties", "js", "jsx", "ts", "tsx",
        "mjs", "cjs", "mts", "cts", "py", "pyw", "rb", "go", "rs", "java", "kt", "kts", "scala", "c", "h", "cpp", "hpp",
        "cc", "cxx", "cs", "fs", "fsx", "swift", "php", "pl", "pm", "lua", "r", "jl", "ex", "exs", "erl", "hrl", "clj",
        "cljs", "cljc", "elm", "hs", "ml", "mli", "v", "sv", "vhd", "vhdl", "asm", "s", "html", "htm", "xhtml", "xml",
        "svg", "css", "scss", "sass", "less", "vue", "svelte", "astro", "sh", "bash", "zsh", "fish", "ps1", "psm1",
        "psd1", "bat", "cmd", "csv", "tsv", "sql", "graphql", "gql", "prisma", "md", "mdx", "markdown", "rst", "txt",
        "text", "rtf", "tex", "latex", "org", "adoc", "asciidoc", "makefile", "cmake", "gradle", "dockerfile",
        "containerfile", "vagrantfile", "rakefile", "gemfile", "podfile", "fastfile", "brewfile", "procfile", "lock",
        "sum", "log", "diff", "patch", "gitignore", "gitattributes", "editorconfig", "prettierrc", "eslintrc",
        "babelrc", "npmrc", "nvmrc", "yarnrc",
    ]

    private static let textFileNames: Set<String> = [
        "license", "readme", "changelog", "authors", "contributors", "copying",
    ]

    static func kind(of url: URL) -> Attachment.Kind {
        if url.hasDirectoryPath { return .other }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .pdf) == true { return .pdf }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if type?.conforms(to: .text) == true || type?.preferredMIMEType.map(textMIMETypes.contains) == true
            || textExtensions.contains(ext) || textExtensions.contains(name) || textFileNames.contains(name)
        {
            return .text
        }
        return .other
    }

    // MARK: Sources

    /// Files copied in Finder, else a copied image (a screenshot, or one from a browser, Slack,
    /// Preview or Photos); nil means "paste as text".
    @MainActor static func fromPasteboard(_ pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        guard !isText(pasteboard.string(forType: .string)), let data = imageData(pasteboard), let url = saveImage(data)
        else { return nil }
        return [url]
    }

    /// The image on a pasteboard, in the first of its types an image can be read from (PNG,
    /// TIFF, JPEG, HEIC, …).
    static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        let readable = Set(NSBitmapImageRep.imageTypes)
        guard let type = pasteboard.types?.first(where: { readable.contains($0.rawValue) }) else { return nil }
        return pasteboard.data(forType: type)
    }

    /// Whether the text copied alongside an image is what was copied: not when it's only the
    /// image's address or file name (browsers and Slack add those), but a spreadsheet's or an
    /// editor's text that comes with a picture of itself is.
    static func isText(_ string: String?) -> Bool {
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !text.contains(where: \.isNewline) else { return true }
        if let scheme = URL(string: text)?.scheme?.lowercased(), ["http", "https", "file", "data"].contains(scheme) {
            return false
        }
        return UTType(filenameExtension: (text as NSString).pathExtension)?.conforms(to: .image) != true
    }

    /// Dropped files or image data, delivered on the main actor.
    static func load(_ providers: [NSItemProvider], into deliver: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in deliver([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, let url = saveImage(data) else { return }
                    Task { @MainActor in deliver([url]) }
                }
            }
        }
    }

    /// Pasted/dropped image data as a PNG file (Codex takes images by path).
    static func saveImage(_ data: Data) -> URL? {
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kore", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Image \(UUID().uuidString.prefix(6)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    // MARK: Encoding

    /// What gets sent; plain values so encoding can run off the main actor.
    package struct File: Sendable {
        package let url: URL
        package let name: String
        package let kind: Attachment.Kind

        package init(url: URL, name: String, kind: Attachment.Kind) {
            self.url = url
            self.name = name
            self.kind = kind
        }
    }

    static func files(_ attachments: [Attachment]) -> [File] {
        attachments.compactMap { a in a.url.map { File(url: $0, name: a.name, kind: a.kind) } }
    }

    static func claudeContent(text: String, files: [File], folder: URL) -> JSONValue {
        var blocks: [JSONValue] = []
        var references: [String] = []
        for file in files {
            switch file.kind {
            case .image:
                if let (mediaType, data) = imagePayload(file.url) {
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())],
                    ])
                    continue
                }
            case .text:
                if let data = try? Data(contentsOf: file.url), data.count <= maxTextBytes,
                    let contents = String(data: data, encoding: .utf8)
                {
                    blocks.append([
                        "type": "document", "title": .string(file.name),
                        "source": ["type": "text", "media_type": "text/plain", "data": .string(contents)],
                    ])
                    continue
                }
            case .pdf:
                if let data = try? Data(contentsOf: file.url), data.count <= maxPDFBytes {
                    blocks.append([
                        "type": "document", "title": .string(file.name),
                        "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64EncodedString())],
                    ])
                    continue
                }
            case .other:
                break
            }
            // Folders, binaries, and anything too large: point Claude at it to use its tools on.
            references.append("@" + relativePath(file.url, in: folder))
        }
        let body = ([text] + (references.isEmpty ? [] : [references.joined(separator: " ")]))
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !body.isEmpty { blocks.append(["type": "text", "text": .string(body)]) }
        return .array(blocks)
    }

    static func codexInput(text: String, files: [File]) -> JSONValue {
        var items: [JSONValue] = files.map { file in
            file.kind == .image
                ? ["type": "localImage", "path": .string(file.url.path)]
                : ["type": "mention", "name": .string(file.name), "path": .string(file.url.path)]
        }
        if !text.isEmpty { items.append(["type": "text", "text": .string(text), "text_elements": []]) }
        // A mention reaches only the display: the model is told of the files in a text of its
        // own, after the user's, which reading back leaves out (`isFileNote`). A text file comes
        // whole, as Claude gets it; any other, by its path, for the model to open.
        let note = files.filter { $0.kind != .image }.map(fileNote)
        if !note.isEmpty { items.append(["type": "text", "text": .string(note.joined(separator: "\n\n")), "text_elements": []]) }
        return .array(items)
    }

    static func fileNote(_ file: File) -> String {
        if file.kind == .text, let data = try? Data(contentsOf: file.url), data.count <= maxCodexTextBytes,
            let contents = String(data: data, encoding: .utf8)
        {
            return "[file: \(file.url.path)]\n\(contents)\n[/file]"
        }
        return "[file: \(file.url.path)] (attached: open it with your tools)"
    }

    /// Kore's text naming a Codex message's attached files: an item of its own, from "[file: /".
    static func isFileNote(_ text: String) -> Bool { text.hasPrefix("[file: /") }

    // MARK: Transcripts

    /// Image and document blocks of a Claude user message, for showing past messages.
    static func chips(fromClaude content: JSONValue) -> [Attachment] {
        (content.array ?? []).compactMap { block in
            switch block["type"]?.string {
            case "image":
                let data = block["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) }
                return Attachment(name: "Image", kind: .image, thumbnail: data.flatMap(NSImage.init(data:)))
            case "document":
                let isPDF = block["source"]?["media_type"]?.string == "application/pdf"
                return Attachment(name: block["title"]?.string ?? "Document", kind: isPDF ? .pdf : .text)
            default:
                return nil
            }
        }
    }

    /// localImage / mention items of a Codex user message.
    static func chips(fromCodex content: JSONValue) -> [Attachment] {
        (content.array ?? []).compactMap { item in
            guard let path = item["path"]?.string else { return nil }
            switch item["type"]?.string {
            case "localImage", "mention": return Attachment(url: URL(fileURLWithPath: path))
            default: return nil
            }
        }
    }

    // MARK: Limits and images

    private static let maxTextBytes = 2_000_000
    /// A text file a Codex message carries whole (about 25k tokens); a bigger one goes by its path.
    private static let maxCodexTextBytes = 100_000
    private static let maxPDFBytes = 32_000_000
    /// Anthropic's limits: 5MB per image once base64-encoded; large images are downscaled anyway.

    /// Media type and bytes for an image block: the file as-is when it is a supported type
    /// within limits, else re-encoded (PNG, or JPEG if still too big) at most 2000px a side.
    static func imagePayload(_ url: URL) -> (String, Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        return ImageFit.fit(data, mediaType: types[url.pathExtension.lowercased()]).map { ($0.mediaType, $0.data) }
    }

    static func relativePath(_ url: URL, in folder: URL) -> String {
        let root = folder.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }
}
