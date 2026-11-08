import Foundation
import HostClient
import src

/// Where Arsenal's fetches and asks' files come from and land (`ArsenalFetch`): each window's
/// folder as a place, the boxes by name, and their links held for a carry.
extension Workspace {
    /// The window's folder: this Mac's, or a box's as the box names it.
    package var arsenalPlace: FilePlace {
        guard let box else { return .mac(folder.path) }
        return .box(alias: box.alias, path: box.shownFolder)
    }

    /// Whether `place` is this window's folder: this Mac's with its links followed, or a box's as
    /// it names it (its path there, or as the window was opened with).
    package func arsenalIsFolder(_ place: FilePlace) -> Bool {
        switch (place, box) {
        case (.mac(let path), nil):
            return ArsenalFetch.real(path) == ArsenalFetch.real(folder.path)
        case (.box(let alias, let path), let box?):
            return box.alias == alias && [box.shownFolder, box.folder].map(ArsenalFetch.normalized).contains(ArsenalFetch.normalized(path))
        default:
            return false
        }
    }

    /// The asker's inbox, inside its window's folder.
    package var arsenalInbox: FilePlace {
        var place = arsenalPlace
        for part in ArsenalFetch.inbox.split(separator: "/") { place = place.child(String(part)) }
        return place
    }

    /// Open windows' folders on the device of `place`: this Mac's, or that box's.
    package static func arsenalRoots(on alias: String?) -> [String] {
        all.allObjects.filter { !$0.isClosed && $0.box?.alias == alias }.map { $0.arsenalPlace.path }
    }

    /// The boxes a window has open, by their shown name and alias (and each lowercased), for
    /// `device:path`.
    package static func arsenalBoxNames() -> [String: String] {
        var names: [String: String] = [:]
        for box in all.allObjects.filter({ !$0.isClosed }).compactMap(\.box) {
            for name in [box.alias, NodeNames.name(box.alias)] {
                names[name] = box.alias
                names[name.lowercased()] = box.alias
            }
        }
        return names
    }

    /// The boxes a carry reaches, their links held until `release`.
    package static func arsenalBoxes(_ aliases: Set<String>) -> (boxes: [String: CarryBox], release: @MainActor () -> Void) {
        var boxes: [String: CarryBox] = [:]
        var held: [HostConnection] = []
        for alias in aliases {
            let reached = FileCarries.shared.reach(alias)
            reached.connection.retain()
            held.append(reached.connection)
            boxes[alias] = reached.box
        }
        return (boxes, { for connection in held { connection.release() } })
    }
}
