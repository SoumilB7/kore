import Foundation

/// A folder followed by identity rather than by path: a bookmark, which keeps pointing at the
/// same folder after it's renamed or moved. (A file reference URL would too, but Swift's `URL`
/// turns it back into a path.)
public struct FolderIdentity: Sendable {
    private let bookmark: Data?

    public init(_ folder: URL) {
        bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folder is now; nil once it's deleted, in the Trash, or its volume is gone.
    public func current() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let path = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        if path.pathComponents.contains(".Trash") { return nil }
        return path
    }
}

/// A path under a folder that moved, at its new place: `old/a/b` → `new/a/b`; nil for a path
/// outside the old folder.
public func remapped(_ path: String, from old: String, to new: String) -> String? {
    func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
    let path = trimmed(path), old = trimmed(old), new = trimmed(new)
    if path == old { return new }
    guard path.hasPrefix(old + "/") else { return nil }
    return new + path.dropFirst(old.count)
}
