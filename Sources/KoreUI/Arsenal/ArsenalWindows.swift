import AppKit
import HostClient
import KoreCore
import src

/// Another folder's window for an agent's new chat (`kore new --folder`, Act device): the open one,
/// or one opened for it, in front or quietly (`--silent`: behind, not key, Kore not activated).
/// Each way a window is opened, raised or a box is checked is a seam, so tests see what happened.
@MainActor
package enum ArsenalWindows {
    /// Opens a window on `place` as a folder from outside opens one; `quiet`: behind the window
    /// that's key, which stays key, and Kore isn't activated.
    package static var open: @MainActor (FilePlace, _ quiet: Bool) -> Void = { place, quiet in
        switch place {
        case .mac(let path):
            let folder = AppModel.canonical(URL(fileURLWithPath: path, isDirectory: true))
            if quiet { Workspace.quietOpens.insert(folder.standardizedFileURL.path) }
            AppModel.shared?.openFolder(folder)
        case .box(let alias, let path):
            if quiet { Workspace.quietOpens.insert(BoxBinding.key(BoxPlace(alias: alias, folder: path))) }
            AppModel.shared?.storyOpenBox(alias: alias, folder: path)
        }
    }

    /// An open window to the front, as a click on it brings it; Kore isn't activated.
    package static var front: @MainActor (Workspace) -> Void = { workspace in
        guard let window = workspace.window else { return }
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    /// The boxes Kore has, by their shown name and alias (and each lowercased): those a window has
    /// open, and those in its list.
    package static var boxNames: @MainActor () -> [String: String] = {
        var names = Workspace.arsenalBoxNames()
        for alias in BoxList.shared.boxes.map(\.alias) {
            for name in [alias, NodeNames.name(alias)] where names[name] == nil {
                names[name] = alias
                names[name.lowercased()] = alias
            }
        }
        return names
    }

    /// Why a chat can't open in `path` on the box now: not connected, or no folder there.
    package static var boxReady: @MainActor (_ alias: String, _ path: String) async -> ArsenalRefusal? = { alias, path in
        guard HostConnection.existing(alias)?.phase == .online else { return notConnected(alias) }
        let held = Workspace.arsenalBoxes([alias])
        defer { held.release() }
        guard let box = held.boxes[alias] else { return notConnected(alias) }
        switch await box.files.count(path) {
        case .success(let count) where count.dir: return nil
        case .success: return .init("\(path) on \(NodeNames.name(alias)) is a file, not a folder.")
        case .failure: return .init("\(path) isn't a folder on \(NodeNames.name(alias)).")
        }
    }

    /// The line a box chat's tools give when the Mac isn't there, said here of a box.
    package static func notConnected(_ alias: String) -> ArsenalRefusal {
        .init("Kore isn't connected to \(NodeNames.name(alias)) right now.")
    }

    /// How many turns of the main actor a window just asked for may take to come up, a frame apart.
    package static var patience = 200

    /// The window `given` names (a path on the caller's device, `~` and links resolved, or
    /// `device:path`): an existing directory, on this Mac or a connected box Kore has. `opened`:
    /// no window had it, so one was opened (`quiet` as `open` takes it).
    package static func window(_ given: String, from home: Workspace, quiet: Bool) async -> Result<(window: Workspace, opened: Bool), ArsenalRefusal> {
        let place: FilePlace
        switch ArsenalFetch.place(given, base: home.arsenalPlace, names: boxNames()) {
        case .failure(.noDevice(let name)): return .failure(.init("Kore has no box named \(name)."))
        case .failure(let refusal): return .failure(.init(refusal.line))
        case .success(.mac(let path)):
            let real = ArsenalFetch.real(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir) else { return .failure(.init("\(given) isn't there.")) }
            guard isDir.boolValue else { return .failure(.init("\(given) is a file, not a folder.")) }
            place = .mac(real)
        case .success(.box(let alias, let path)):
            let path = ArsenalFetch.normalized(path)
            if let refusal = await boxReady(alias, path) { return .failure(refusal) }
            place = .box(alias: alias, path: path)
        }
        if let found = shown(place) { return .success((found, false)) }
        open(place, quiet)
        for _ in 0..<patience {
            if let found = shown(place) { return .success((found, true)) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let found = shown(place) { return .success((found, true)) }
        return .failure(.init("Kore opened a window for \(given), but it isn't ready yet: ask again in a moment."))
    }

    /// The open window whose folder `place` is.
    static func shown(_ place: FilePlace) -> Workspace? {
        Workspace.all.allObjects.first { !$0.isClosed && $0.window != nil && $0.arsenalIsFolder(place) }
    }

    /// A window opened quietly, put behind the one that was key once SwiftUI has shown it.
    static func lower(_ window: NSWindow) {
        let prior = NSApp.keyWindow.flatMap { $0 === window ? nil : $0 }
        DispatchQueue.main.async {
            if let prior, prior.isVisible {
                window.order(.below, relativeTo: prior.windowNumber)
                prior.makeKey()
            } else {
                window.orderBack(nil)
            }
        }
    }
}
