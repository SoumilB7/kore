import AppKit
import Darwin
import KoreCore

extension Workspace {
    package func storyPrepareTerminals() throws {
        let config = folder.appendingPathComponent(".terminal-test", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PROMPT='ready> '\nRPROMPT=''\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        // The storyline host keeps its windows off screen; screenshots still need native frames.
        terminals.suspendsRenderingWhenNotVisible = false
        terminals.environment = ["HOME": config.path, "ZDOTDIR": config.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    package var storyTerminal: (open: Bool, count: Int, shell: Bool, text: String, focused: Bool, foreground: Int, id: UUID?) {
        let entry = terminals.active
        return (terminals.isOpen, terminals.entries.count, entry?.shell != nil,
                entry.map { String(decoding: $0.view.getBufferAsData(), as: UTF8.self) } ?? "",
                entry.map { window?.firstResponder === $0.view } ?? false, terminals.workingCount, entry?.id)
    }
    package var storyTerminalTitle: String? { terminals.active?.title }
    package var storyTerminalIDs: [UUID] { terminals.entries.map(\.id) }

    package func storyPaintTerminal() {
        guard let view = terminals.active?.view else { return }
        view.needsDisplay = true
        view.display()
    }
    package func storyTerminalVisible() { terminals.windowVisible = true }
    package var storyTerminalChildren: [ProcessChild] { terminals.entries.compactMap { $0.shell?.child } }
    package var storyTerminalHeight: CGFloat { terminals.height }
    package var storyTerminalMaximized: Bool { terminals.maximized }
}
