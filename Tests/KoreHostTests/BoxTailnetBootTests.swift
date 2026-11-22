import Foundation
import Testing

@testable import KoreHost

/// kore-host before tailscaled at boot (KoreNet review item 8), and a box without linger.
@Suite("box tailnet at boot, linger off")
struct BoxTailnetBootTests {
    @Test func aStartingTailscaledIsWaitedForAStoppedOneIsNot() {
        #if os(Linux)
        #expect(BoxTailnet.tailscaledStarting(run: { _ in "activating\n" }, enabled: { _ in "enabled" }, uptime: { 9999 }))
        // Started, its socket not there yet: still coming up.
        #expect(BoxTailnet.tailscaledStarting(run: { _ in "active" }, enabled: { _ in "enabled" }, uptime: { 9999 }))
        #expect(BoxTailnet.tailscaledStarting(run: { _ in "inactive\n" }, enabled: { _ in "enabled\n" }, uptime: { 20 }))
        #expect(!BoxTailnet.tailscaledStarting(run: { _ in "inactive" }, enabled: { _ in "enabled" }, uptime: { 3600 }))
        #expect(!BoxTailnet.tailscaledStarting(run: { _ in "inactive" }, enabled: { _ in "disabled" }, uptime: { 20 }))
        #expect(!BoxTailnet.tailscaledStarting(run: { _ in "failed" }, enabled: { _ in "enabled" }, uptime: { 20 }))
        #else
        #expect(!BoxTailnet.tailscaledStarting(run: { _ in "activating" }, enabled: { _ in "enabled" }, uptime: { 1 }))
        #endif
    }

    @Test func withoutLingerItRunsOnItsOwnInsteadOfAUnitThatDiesAtLogout() throws {
        let home = URL(fileURLWithPath: "/tmp/khl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HostPaths(environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.path + "/config", "XDG_STATE_HOME": home.path + "/state", "XDG_RUNTIME_DIR": home.path + "/run"])
        let ran = Lines()
        let lines = try HostService.install(.systemd, executable: "/opt/kore-host", home: home, user: "u", paths: paths) { args in
            ran.add(args.joined(separator: " "))
            return HostRan(status: args.first == "loginctl" ? 1 : 0)
        }
        #expect(lines.first == HostService.lingerOff("u"))
        #expect(lines.contains { $0.contains("kore-host is running") })
        #expect(HostService.installed(paths) == .onDemand)
        #expect(!ran.all.contains { $0.hasPrefix("systemctl --user enable") })
        #expect(!FileManager.default.fileExists(atPath: HostService.unitFile(home: home).path))
    }
}
