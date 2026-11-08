import Foundation
import KoreCore
import UniformTypeIdentifiers

/// What a file attached to a message is, for how it's sent and shown.
package enum AttachmentKind: Sendable { case image, text, pdf, other }

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

    package static func kind(of url: URL) -> AttachmentKind {
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

    // MARK: Encoding

    /// What gets sent; plain values so encoding can run off the main actor.
    package struct File: Sendable {
        package let url: URL
        package let name: String
        package let kind: AttachmentKind

        package init(url: URL, name: String, kind: AttachmentKind) {
            self.url = url
            self.name = name
            self.kind = kind
        }
    }

    /// `media`: the video and audio among `files`, read (`AttachedMedia.read`).
    package static func claudeContent(text: String, files: [File], folder: URL, media: [URL: AttachedMedia] = [:]) -> JSONValue {
        var blocks: [JSONValue] = []
        var references: [String] = []
        var notes: [String] = []
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
                // A video as its frames, audio as its line: never handed to the CLI to read.
                if let media = media[file.url] {
                    for frame in media.frames {
                        guard let (mediaType, data) = imagePayload(frame) else { continue }
                        blocks.append([
                            "type": "image",
                            "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())],
                        ])
                    }
                    notes.append(media.note)
                    continue
                }
            }
            // A folder: Claude is pointed at it, to use its tools on. Any other file (a binary, one
            // too large) is named, not handed to the CLI to read whole as an @ reference.
            if isFolder(file.url) {
                references.append("@" + relativePath(file.url, in: folder))
            } else {
                notes.append("[file: \(file.url.path)]")
            }
        }
        let body = ([text] + (references.isEmpty ? [] : [references.joined(separator: " ")]) + notes)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !body.isEmpty { blocks.append(["type": "text", "text": .string(body)]) }
        return .array(blocks)
    }

    /// A folder on disk, whatever its URL says (one without a trailing slash doesn't).
    package static func isFolder(_ url: URL) -> Bool {
        url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    package static func codexInput(text: String, files: [File], media: [URL: AttachedMedia] = [:]) -> JSONValue {
        var items: [JSONValue] = files.map { file in
            file.kind == .image
                ? ["type": "localImage", "path": .string(file.url.path)]
                : ["type": "mention", "name": .string(file.name), "path": .string(file.url.path)]
        }
        // A video's frames, as images.
        items += files.flatMap { media[$0.url]?.frames ?? [] }.map { ["type": "localImage", "path": .string($0.path)] }
        if !text.isEmpty { items.append(["type": "text", "text": .string(text), "text_elements": []]) }
        // A mention reaches only the display: the model is told of the files in a text of its
        // own, after the user's, which reading back leaves out (`isFileNote`). A text file comes
        // whole, as Claude gets it; any other, by its path, for the model to open.
        let note = files.filter { $0.kind != .image }.map { media[$0.url]?.note ?? fileNote($0) }
        if !note.isEmpty { items.append(["type": "text", "text": .string(note.joined(separator: "\n\n")), "text_elements": []]) }
        return .array(items)
    }

    package static func fileNote(_ file: File) -> String {
        if file.kind == .text, let data = try? Data(contentsOf: file.url), data.count <= maxCodexTextBytes,
            let contents = String(data: data, encoding: .utf8)
        {
            return "[file: \(file.url.path)]\n\(contents)\n[/file]"
        }
        return "[file: \(file.url.path)] (attached: open it with your tools)"
    }

    /// Kore's text naming a Codex message's attached files: an item of its own, from "[file: /".
    package static func isFileNote(_ text: String) -> Bool {
        ["[file: /", "[video: /", "[audio: /"].contains { text.hasPrefix($0) }
    }

    // MARK: Limits and images

    private static let maxTextBytes = 2_000_000
    /// A text file a Codex message carries whole (about 25k tokens); a bigger one goes by its path.
    private static let maxCodexTextBytes = 100_000
    private static let maxPDFBytes = 32_000_000
    /// Claude's limits: 5MB per image once base64-encoded; large images are downscaled anyway.

    /// Media type and bytes for an image block: the file as-is when it is a supported type
    /// within limits, else re-encoded (PNG, or JPEG if still too big) at most 2000px a side.
    package static func imagePayload(_ url: URL) -> (String, Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        return ImageFit.fit(data, mediaType: types[url.pathExtension.lowercased()]).map { ($0.mediaType, $0.data) }
    }

    package static func relativePath(_ url: URL, in folder: URL) -> String {
        let root = folder.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }
}
