import SwiftUI

/// What a file's icon shows (look §3): an SF Symbol where one fits the kind, else a two-letter
/// monogram (TS, PY, GO). One colour, the row's: the git state's, else the text's or secondary.
/// A name costs one or two dictionary lookups, no switch or path parsing per redraw.
enum FileGlyph: Hashable, Sendable {
    case file, text, markdown, swift, json, html, xml, css, sql, shell, config, env, gitignore, lock
    case image, pdf, docker, make, archive, audio, video, table, notebook, font
    case typescript, javascript, python, go, rust, java, kotlin, c, cpp, header

    /// The SF Symbol, or nil for a monogram.
    var symbol: String? {
        switch self {
        case .file: "doc"
        case .text: "doc.text"
        case .markdown: "text.alignleft"
        case .swift: "swift"
        case .json: "curlybraces"
        case .html, .xml: "chevron.left.forwardslash.chevron.right"
        case .css: "number"
        case .sql: "cylinder"
        case .shell: "terminal"
        case .config: "slider.horizontal.3"
        case .env: "key"
        case .gitignore: "arrow.triangle.branch"
        case .lock: "lock"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .docker: "cube"
        case .make: "hammer"
        case .archive: "archivebox"
        case .audio: "waveform"
        case .video: "film"
        case .table: "tablecells"
        case .notebook: "book.pages"
        case .font: "textformat"
        case .typescript, .javascript, .python, .go, .rust, .java, .kotlin, .c, .cpp, .header: nil
        }
    }

    /// The two letters drawn for a language with no symbol of its own.
    var monogram: String? {
        switch self {
        case .typescript: "TS"
        case .javascript: "JS"
        case .python: "PY"
        case .go: "GO"
        case .rust: "RS"
        case .java: "JV"
        case .kotlin: "KT"
        case .c: "C"
        case .cpp: "C+"
        case .header: "H"
        default: nil
        }
    }

    static func of(_ name: String) -> FileGlyph {
        let lower = name.lowercased()
        if let glyph = byName[lower] { return glyph }
        if lower.hasPrefix(".env") { return .env }
        if lower.hasPrefix("dockerfile") { return .docker }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return .file }
        return byExt[String(lower[lower.index(after: dot)...])] ?? .file
    }

    /// Whole names (lowercased) that say more than their extension.
    private static let byName: [String: FileGlyph] = [
        "dockerfile": .docker, "containerfile": .docker, ".dockerignore": .docker,
        "makefile": .make, "gnumakefile": .make, "justfile": .make,
        ".gitignore": .gitignore, ".gitattributes": .gitignore, ".gitmodules": .gitignore, ".gitkeep": .gitignore,
        ".env": .env, "package.resolved": .lock, "go.mod": .go, "go.sum": .lock,
        "license": .text, "readme": .markdown,
    ]

    private static let byExt: [String: FileGlyph] = {
        var map: [String: FileGlyph] = [:]
        let table: [(FileGlyph, String)] = [
            (.swift, "swift"), (.json, "json jsonc json5 jsonl"), (.html, "html htm vue svelte"),
            (.xml, "xml plist svg xib storyboard entitlements"), (.css, "css scss sass less"), (.sql, "sql sqlite db"),
            (.shell, "sh zsh bash fish command ps1"), (.markdown, "md markdown mdx"), (.text, "txt rtf log"),
            (.config, "yml yaml toml ini cfg conf properties editorconfig"), (.env, "env"), (.lock, "lock resolved"),
            (.image, "png jpg jpeg gif heic webp icns tiff bmp ico avif"), (.pdf, "pdf"),
            (.archive, "zip tar gz tgz bz2 xz 7z rar dmg"), (.audio, "mp3 wav m4a aac flac ogg aiff"),
            (.video, "mp4 mov m4v webm mkv avi"), (.table, "csv tsv xlsx numbers"), (.notebook, "ipynb"),
            (.font, "ttf otf woff woff2"), (.typescript, "ts tsx mts cts"), (.javascript, "js jsx mjs cjs"),
            (.python, "py pyi pyw"), (.go, "go"), (.rust, "rs"), (.java, "java"), (.kotlin, "kt kts"), (.c, "c m"),
            (.cpp, "cc cpp cxx mm"), (.header, "h hh hpp hxx"), (.make, "mk"),
        ]
        for (glyph, extensions) in table {
            for ext in extensions.split(separator: " ") { map[String(ext)] = glyph }
        }
        return map
    }()
}

/// A file's glyph in its 14 box. A folder takes the same box, so names line up beside it.
struct FileIconView: View {
    let name: String
    var color: Color = Theme.secondary
    var isFolder = false

    var body: some View {
        let glyph = isFolder ? nil : FileGlyph.of(name)
        Group {
            if let monogram = glyph?.monogram {
                Text(monogram)
                    .font(Chrome.glyphFileMonogram)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(systemName: glyph?.symbol ?? "folder")
                    .font(Chrome.glyphTreeIcon)
            }
        }
        .foregroundStyle(glyph.flatMap(Theme.FileType.tint) ?? color)
        .frame(width: Size.Tree.icon, height: Size.Tree.icon)
    }
}
