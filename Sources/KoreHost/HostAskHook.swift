import AgentTools
import Foundation
import src

/// `kore-host hook pretool`: a box Auto chat's PreToolUse hook, the same list as the Mac's
/// `kore hook pretool` (`KoreAskList`).
package enum HostAskHook {
    package static func run() -> Int32 { KoreAskList.runHook() }

    /// The box's Claude chats launch with this kore-host as their hook.
    @MainActor package static func install() { ClaudeBackend.askHook = ClaudeBackend.quoted(HostService.executable()) + " hook pretool" }
}
