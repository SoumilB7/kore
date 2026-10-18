import Foundation

/// One user storyline: what a person does in Kore, and what they should see (phase 12).
///
/// A storyline is a small subclass that lists its steps. Families (`ChatStoryline`,
/// `ResumeStoryline`, …) add shared opening steps, and the runner finds every concrete subclass
/// at run time, so adding a storyline is adding a file.
@MainActor
package class Storyline: NSObject {
    /// For filtering runs: `--tag fork,gate`.
    package class var tags: Set<Tag> { [] }
    /// What it needs set up before its first step.
    package class var needs: Needs { Needs() }
    /// Runs once per variant (`[.claude, .codex]` for a story both providers tell).
    package class var variants: [Variant] { [.only] }
    /// Families (classes that only exist to be subclassed) aren't run themselves. A family says
    /// so for itself only (`self == ChatStoryline.self`), since subclasses inherit the answer.
    package class var isFamily: Bool { false }

    /// The variant this run tells.
    package internal(set) var variant: Variant = .only

    nonisolated package required override init() { super.init() }

    /// The story, top to bottom.
    package func steps() -> [any Step] { [] }

    /// The name in reports and `--name`.
    package class var storyName: String { String(describing: self) }
}

/// A label for picking storylines to run.
package struct Tag: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    package let name: String
    package init(_ name: String) { self.name = name }
    package init(stringLiteral value: String) { name = value }
    package var description: String { name }

    /// Runs before every landing (verify-landing's gate).
    package static let gate: Tag = "gate"
    package static let chat: Tag = "chat"
    package static let resume: Tag = "resume"
    package static let claude: Tag = "claude"
    package static let codex: Tag = "codex"
    package static let fork: Tag = "fork"
    package static let editor: Tag = "editor"
    package static let explorer: Tag = "explorer"
    package static let files: Tag = "files"
    package static let agents: Tag = "agents"
    package static let approvals: Tag = "approvals"
    /// Needs a live model (`--live`).
    package static let live: Tag = "live"
    /// Presses real shortcuts through the window server: runs only with `--real-input` (the
    /// owner OKs each such run in chat), and reports as skipped otherwise.
    package static let realInput: Tag = "realinput"
}

/// One telling of a storyline.
package struct Variant: Hashable, Sendable, CustomStringConvertible {
    package let name: String
    /// The provider it runs, when it's a per-provider variant.
    package let provider: String?

    package static let only = Variant(name: "", provider: nil)
    package static let claude = Variant(name: "claude", provider: "claude")
    package static let codex = Variant(name: "codex", provider: "codex")

    package var description: String { name }
}

/// What a storyline needs before its first step.
package struct Needs: Sendable {
    package enum Folder: Sendable {
        /// A new empty folder in the run's scratch area.
        case empty
        /// A recorded session's folder, by its name in `--replay` (verify-landing's fixtures).
        case replay(String)
    }

    /// Which CLI its chats talk to.
    package enum CLI: Sendable {
        /// The run's CLI (`--cli scripted`, the default; `--cli process`; `--live <model>`).
        case run
        /// The real `claude` / `codex` on the owner's own stores, whatever the run's mode: the
        /// recorded sessions verify-landing replays (`--replay`).
        case real
    }

    package var folder: Folder = .empty
    package var cli: CLI = .run
    /// The window's content size; the runner's `--size` overrides it.
    package var window = CGSize(width: 1000, height: 760)

    package init(folder: Folder = .empty, cli: CLI = .run, window: CGSize = CGSize(width: 1000, height: 760)) {
        self.folder = folder
        self.cli = cli
        self.window = window
    }
}
