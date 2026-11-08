import Foundation

/// A phone's folder browser on a box (an act grant, phase 18): `fs.list` (folders only),
/// `fs.mkdir` and `folder.add`, inside the box user's home only and never through a hidden name
/// (`.ssh`, `.config`, `.local`…). A full grant (the Mac) keeps `checkBox`'s rules. The box also
/// checks where the path really leads (its links resolved) before it lists, makes or adds.
extension LinkPolicy {
    /// Why an act grant's browse or add is refused, or `.allow`. `home` is the box user's home.
    package static func checkHomeFolders(_ kind: ControlKind, _ args: ControlArgs, home: String) -> Verdict {
        switch kind {
        case .fsList, .fsMkdir, .folderAdd: break
        default: return .deny(.deniedControl, "That needs a grant with full control.")
        }
        if args.hidden == true { return .deny(.deniedPath, hiddenRefused) }
        // `fs.list` with no path: the home itself.
        if kind == .fsList, args.path == nil { return .allow }
        guard LinkFiles.plainPath(args.path), let path = args.path else { return .deny(.invalid, "An absolute path.") }
        let root = LinkFiles.normalised(home)
        let wanted = LinkFiles.normalised(path)
        guard LinkFiles.inside(wanted, root) else { return .deny(.deniedPath, "Only folders in your home on the box.") }
        let below = wanted.dropFirst(root == "/" ? 0 : root.count).split(separator: "/")
        guard !below.contains(where: { $0.hasPrefix(".") }) else { return .deny(.deniedPath, hiddenRefused) }
        if kind == .fsMkdir {
            guard let name = below.last, name.utf8.count <= 255 else { return .deny(.invalid, "Name the new folder.") }
        }
        return .allow
    }

    package static let hiddenRefused = "Hidden folders aren't opened from a phone."
}
