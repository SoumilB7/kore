import Foundation

/// Each chat's pass for Kore's agent channel (`z-docs/agent-protocol.md`): a random value in its
/// CLI's environment, so what runs under that CLI can name its chat. Kore believes it only when
/// the caller also runs under the process that was started with it.
package final class AgentPasses: @unchecked Sendable {
    /// The variable a chat's CLI gets. Its name holds none of the words Codex strips from a tool
    /// shell's environment (KEY, SECRET, TOKEN).
    package static let variable = "KORE_AGENT_PASS"

    package static let shared = AgentPasses()

    private let lock = NSLock()
    /// The running CLIs started with a pass, by pass.
    private var running: [String: ProcessChild] = [:]

    /// A new pass: 24 random bytes, URL-safe base64.
    package static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// A CLI started with `environment`: its pass, if any, now names it.
    func started(_ pid: pid_t, environment: [String: String]?) {
        guard let pass = environment?[Self.variable], let child = ProcessChild(pid) else { return }
        lock.withLock { running[pass] = child }
    }

    package func ended(_ pid: pid_t) {
        lock.withLock { running = running.filter { $0.value.pid != pid } }
    }

    /// The live CLIs' pids, by pass (one that has exited, or whose pid was reused, is left out).
    package func pids() -> [String: pid_t] {
        lock.withLock { running }.filter(\.value.alive).mapValues(\.pid)
    }

    /// Records a process as started with `pass` (tests).
    package func register(_ pass: String, pid: pid_t) {
        guard let child = ProcessChild(pid) else { return }
        lock.withLock { running[pass] = child }
    }
}
