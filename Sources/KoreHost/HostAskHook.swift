import AgentTools
import Foundation
import src

/// `kore-host hook pretool`: a box Auto chat's PreToolUse hook, the same as the Mac's
/// `kore hook pretool` (`KoreAskList`): "ask" only for a Run once pass.
package enum HostAskHook {
    package static func run(_ arguments: [String] = []) -> Int32 { KoreAskList.runHook(arguments) }

    /// The box's Claude chats take this kore-host as their hook while a pass is open.
    @MainActor package static func install() { ClaudeBackend.askHook = ClaudeBackend.quoted(HostService.executable()) + " hook pretool" }
}
