import AppKit
import KoreCore

/// Where a link clicked in a chat goes. A file that's there opens in a Kore tab (an HTML page in
/// its web view), at the line the link names (`path:42`, `#L42`); a folder shows in the
/// explorer; anything else (the web, mail, a file that isn't there) goes to the system, as it
/// always did. A plain or relative path is the chat folder's.
enum ChatLink: Equatable {
    case file(URL, line: Int?)
    case folder(URL)
    case system(URL)

    /// Schemes that are never a path, however their text reads.
    private static let web: Set<String> = ["http", "https", "mailto"]

    init(_ url: URL, folder: URL?) {
        let scheme = url.scheme?.lowercased()
        let path: String
        var line: Int?
        switch scheme {
        case "file", nil:
            path = url.path(percentEncoded: false)
            line = Self.line(fragment: url.fragment(percentEncoded: false))
        case let scheme? where Self.web.contains(scheme):
            self = .system(url)
            return
        default:
            // `notes.md:12` reads as a scheme (`notes.md`) to URL: the whole text is the path.
            let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            path = String(parts[0])
            line = parts.count > 1 ? Self.line(fragment: String(parts[1])) : nil
        }
        self = Self.existing(path, line: line, folder: folder) ?? .system(url)
    }

    /// The path as it stands, else without a `:line` or `:line:column` at its end.
    private static func existing(_ path: String, line: Int?, folder: URL?) -> ChatLink? {
        guard !path.isEmpty else { return nil }
        if let found = find(path, folder: folder) { return found.directory ? .folder(found.url) : .file(found.url, line: line) }
        guard let (bare, named) = trailingLine(path), let found = find(bare, folder: folder), !found.directory else { return nil }
        return .file(found.url, line: named)
    }

    private static func find(_ path: String, folder: URL?) -> (url: URL, directory: Bool)? {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let folder {
            url = folder.appendingPathComponent(expanded)
        } else {
            return nil
        }
        let resolved = url.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory) else { return nil }
        return (resolved, directory.boolValue)
    }

    /// `a.swift:42` → (`a.swift`, 42); `a.swift:42:7` → (`a.swift`, 42).
    static func trailingLine(_ path: String) -> (String, Int)? {
        var rest = Substring(path)
        var numbers: [Int] = []
        while numbers.count < 2, let colon = rest.lastIndex(of: ":"), let n = Int(rest[rest.index(after: colon)...]), n > 0 {
            numbers.insert(n, at: 0)
            rest = rest[..<colon]
        }
        guard let first = numbers.first, !rest.isEmpty else { return nil }
        return (String(rest), first)
    }

    /// `L42`, `L42-L50`, `L42C3`: line 42. Any other fragment names no line.
    static func line(fragment: String?) -> Int? {
        guard let fragment, fragment.first == "L" || fragment.first == "l" else { return nil }
        let digits = fragment.dropFirst().prefix { $0.isASCII && $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }
}

extension Workspace {
    /// Opens a link clicked in one of this window's chats (`ChatLink`). Under storylines the
    /// system gets nothing: each link is noted in `TranscriptSelection.opened`, and one Kore
    /// opened itself in `openedInKore` too.
    func openLink(_ url: URL, from chatFolder: URL?) {
        let story = StoryHost.installed
        if story { TranscriptSelection.opened.append(url) }
        switch ChatLink(url, folder: chatFolder ?? folder) {
        case .file(let file, let line):
            if story { TranscriptSelection.openedInKore.append(url) }
            openFile(file, preview: true, select: line.map { FileDocument.Place(line: $0, columns: 0..<0) })
        case .folder(let directory) where inTree(directory):
            if story { TranscriptSelection.openedInKore.append(url) }
            explorerOpen = true
            sidebar = .explorer
            let store = filesStore()
            let path = realPath(directory.path)
            Task {
                await store.reveal(path)
                store.expand(path)
            }
        default:
            if !story { NSWorkspace.shared.open(url) }
        }
    }

    /// Inside the folder the explorer shows.
    private func inTree(_ url: URL) -> Bool {
        let root = realPath(folder.path), path = realPath(url.path)
        return path == root || path.hasPrefix(root + "/")
    }
}
