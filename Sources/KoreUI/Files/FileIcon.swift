import SwiftUI

/// One monochrome glyph per family of file (look §3): the language shows in the name and the
/// status row, not in colour.
enum FileIcon {
    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if lower.hasSuffix(".lock") || lower.hasSuffix(".resolved") { return "lock" }
        switch ext {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf", "mdx": return "doc.text"
        case "json", "js", "mjs", "cjs", "ts", "jsx", "tsx", "css", "scss", "jsonc": return "curlybraces"
        case "html", "htm", "xml", "svg", "plist", "py", "rb", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm",
            "java", "kt", "php", "lua", "sql", "vue", "svelte":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "zsh", "bash", "fish", "command": return "terminal"
        case "yml", "yaml", "toml", "ini", "env", "cfg", "conf": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "icns", "tiff", "bmp", "ico": return "photo"
        case "pdf": return "doc.richtext"
        default: break
        }
        if lower.hasPrefix(".") || lower == "package.resolved" { return "gearshape" }
        if lower == "makefile" || lower == "dockerfile" { return "terminal" }
        return "doc"
    }
}

/// A file's glyph in its 14 box. A folder takes the same box, so names line up beside it.
struct FileIconView: View {
    let name: String
    var color: Color = Theme.secondary
    var isFolder = false

    var body: some View {
        Image(systemName: isFolder ? "folder" : FileIcon.symbol(for: name))
            .font(Chrome.glyphTreeIcon)
            .foregroundStyle(color)
            .frame(width: Size.Tree.icon, height: Size.Tree.icon)
    }
}
