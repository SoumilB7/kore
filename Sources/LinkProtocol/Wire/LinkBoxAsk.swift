import Foundation

/// Link 1.8's terminal and git messages from a client, read by their type (`t`): each its own
/// shape, so a key typed in a terminal crosses as one small frame and gets no answer.
package enum BoxAsk: Sendable, Equatable {
    case ptyOpen(PtyOpen)
    case ptyAttach(PtyAttach)
    case ptyInput(PtyInput)
    case ptyResize(PtyResize)
    case ptyClose(PtyClose)
    case gitStatus(GitStatusAsk)
    case gitUnwatch(GitUnwatch)
    case gitDiff(GitDiffAsk)
    case gitLineChanges(GitLineChangesAsk)

    /// The types it reads.
    package static let types: Set<String> = [
        PtyOpen.type, PtyAttach.type, PtyInput.type, PtyResize.type, PtyClose.type, GitStatusAsk.type, GitUnwatch.type, GitDiffAsk.type,
        GitLineChangesAsk.type,
    ]

    /// nil for another type, or a message of this type it can't read.
    package static func decode(type: String, _ data: Data) -> BoxAsk? {
        let decoder = JSONDecoder()
        switch type {
        case PtyOpen.type: return (try? decoder.decode(PtyOpen.self, from: data)).map(BoxAsk.ptyOpen)
        case PtyAttach.type: return (try? decoder.decode(PtyAttach.self, from: data)).map(BoxAsk.ptyAttach)
        case PtyInput.type: return (try? decoder.decode(PtyInput.self, from: data)).map(BoxAsk.ptyInput)
        case PtyResize.type: return (try? decoder.decode(PtyResize.self, from: data)).map(BoxAsk.ptyResize)
        case PtyClose.type: return (try? decoder.decode(PtyClose.self, from: data)).map(BoxAsk.ptyClose)
        case GitStatusAsk.type: return (try? decoder.decode(GitStatusAsk.self, from: data)).map(BoxAsk.gitStatus)
        case GitUnwatch.type: return (try? decoder.decode(GitUnwatch.self, from: data)).map(BoxAsk.gitUnwatch)
        case GitDiffAsk.type: return (try? decoder.decode(GitDiffAsk.self, from: data)).map(BoxAsk.gitDiff)
        case GitLineChangesAsk.type: return (try? decoder.decode(GitLineChangesAsk.self, from: data)).map(BoxAsk.gitLineChanges)
        default: return nil
        }
    }

    /// The id its answer carries; nil for those that get none.
    package var id: String? {
        switch self {
        case .ptyOpen(let ask): ask.id
        case .ptyAttach(let ask): ask.id
        case .gitStatus(let ask): ask.id
        case .gitDiff(let ask): ask.id
        case .gitLineChanges(let ask): ask.id
        case .ptyInput, .ptyResize, .ptyClose, .gitUnwatch: nil
        }
    }

    package var isGit: Bool {
        switch self {
        case .gitStatus, .gitUnwatch, .gitDiff, .gitLineChanges: true
        default: false
        }
    }
}

extension LinkPolicy {
    /// 1.8's terminals and git: full grants only, and well-formed. Where a path leads (inside a
    /// served folder, never through a link out of one) the box checks as it runs each.
    package static func checkBox(_ ask: BoxAsk, control: LinkControlLevel) -> Verdict {
        guard control == .full else {
            return .deny(.deniedControl, ask.isGit ? "Git needs a grant with full control." : "A terminal needs a grant with full control.")
        }
        switch ask {
        case .ptyOpen(let open):
            guard LinkFiles.plainPath(open.cwd) else { return .deny(.invalid, "An absolute folder.") }
            guard PtyWire.validSize(open.cols, open.rows) else { return .deny(.invalid, "A size of 1 to 4000 either way.") }
            if let shell = open.shell, !LinkFiles.plainPath(shell) { return .deny(.invalid, "A shell's absolute path.") }
            return .allow
        case .ptyAttach(let attach):
            guard plainID(attach.ptyId) else { return .deny(.invalid, "Name the terminal.") }
            if let after = attach.after, after < 0 { return .deny(.invalid, "A position of 0 or more.") }
            if let cols = attach.cols, let rows = attach.rows, !PtyWire.validSize(cols, rows) { return .deny(.invalid, "A size of 1 to 4000 either way.") }
            return .allow
        case .ptyInput(let input):
            guard plainID(input.ptyId), input.data.utf8.count <= (PtyWire.inputMax / 3 + 1) * 4 else { return .deny(.invalid, "Too much at once.") }
            return .allow
        case .ptyResize(let resize):
            guard plainID(resize.ptyId), PtyWire.validSize(resize.cols, resize.rows) else { return .deny(.invalid, "A size of 1 to 4000 either way.") }
            return .allow
        case .ptyClose(let close):
            return plainID(close.ptyId) ? .allow : .deny(.invalid, "Name the terminal.")
        case .gitStatus(let ask):
            return LinkFiles.plainPath(ask.root) ? .allow : .deny(.invalid, "An absolute folder.")
        case .gitUnwatch(let ask):
            return LinkFiles.plainPath(ask.root) ? .allow : .deny(.invalid, "An absolute folder.")
        case .gitDiff(let ask):
            guard LinkFiles.plainPath(ask.root) else { return .deny(.invalid, "An absolute folder.") }
            if let path = ask.path, !LinkFiles.plainPath(path) { return .deny(.invalid, "An absolute path.") }
            return .allow
        case .gitLineChanges(let ask):
            return LinkFiles.plainPath(ask.path) ? .allow : .deny(.invalid, "An absolute path.")
        }
    }
}

extension StreamWire {
    /// The message's `id`, read without the rest.
    package static func id(_ data: Data) -> String? {
        struct Peek: Decodable { var id: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.id
    }
}
