import Foundation
import HostClient
import KoreHost
import LinkProtocol
import Tailnet
import Testing

/// What a box's tailnet means on this Mac (the four setups and a different account): each
/// report `kore-host upgrade` really prints, read here into the row's one line and action. A Mac
/// box never gets a Linux line; Kore's own tailnet asks for a sign-in on this Mac, never opened by
/// itself. No ssh, no tailnet, no wait.
@MainActor
@Suite("box tailnet on the mac")
struct BoxTailnetJoinTests {
    /// The report a box prints for `seen` on `os`, as the box itself makes it.
    func report(_ seen: HostUpgrade.Tailscale, os: BoxOS, listen: String = "listening 100.64.0.2 port 47470") -> BoxUpgradeReport {
        let root = URL(fileURLWithPath: "/tmp/kj-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("s").path, "XDG_RUNTIME_DIR": root.appendingPathComponent("r").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("c").path,
        ])
        try? HostPaths.privateFolder(paths.runtime)
        var upgrade = HostUpgrade(
            paths: paths, update: { nil }, service: { .running }, installService: { [] }, startDaemon: { true }, linger: { nil },
            tailscale: { _ in seen }, reload: { try? Data((listen + "\n").utf8).write(to: paths.netState) }, listen: { _ in listen })
        upgrade.os = os
        upgrade.version = "0.2.3"
        upgrade.link = "1.12"
        upgrade.home = paths.state.path
        let text = upgrade.run(want: "0.2.3", grant: "MacBook").text.joined(separator: "\n")
        return BoxUpgradeReport.parse(text)!
    }

    func outcome(_ seen: HostUpgrade.Tailscale, os: BoxOS, mac: String? = "owner@example.com") -> BoxNetJoin.Outcome {
        BoxNetJoin.outcome(report(seen, os: os, listen: Self.listen(seen)), name: "mybox", macAccount: mac)
    }

    static func listen(_ seen: HostUpgrade.Tailscale) -> String {
        switch seen {
        case .running, .kore(.running): "listening 100.64.0.2 port 47470"
        default: "not listening: Tailscale is Stopped"
        }
    }

    static let page = "https://login.tailscale.com/a/k0re"

    /// 1 and 3: SSH over Tailscale, Linux or Mac: on, the link moves.
    @Test func runningTailscaleJoinsOnEitherSystem() {
        for os in [BoxOS.linux, .macos] {
            #expect(outcome(.running(node: "nodekey:b", account: "owner@example.com"), os: os) == .link)
            #expect(outcome(.kore(.running(node: "nodekey:k", account: "Owner@Example.com")), os: os) == .link)
        }
    }

    /// 2 and 4: no Tailscale there: Kore's own asks for its owner's sign-in here ("Sign in ↗").
    @Test func koresOwnAsksForASignInHere() {
        for os in [BoxOS.linux, .macos] {
            #expect(outcome(.kore(.signIn(Self.page)), os: os) == .signIn(page: Self.page, kore: true))
            #expect(outcome(.kore(.signIn(nil)), os: os) == .failed("Kore's tailnet on mybox is starting", .tryAgain))
        }
        let join = BoxNetJoin(key: "mybox", name: "mybox")
        join.started(version: "0.2.3")
        let report = report(.kore(.signIn(Self.page)), os: .macos, listen: "not listening")
        join.take(BoxNetJoin.outcome(report, name: "mybox", macAccount: nil), report: report)
        #expect(join.line == "Sign in for mybox" && join.fix == .signIn(Self.page) && join.sidecar)
        #expect(join.rows.map(\.title) == ["kore-host 0.2.3", "Kore's tailnet on mybox", "Sign in for mybox"])
        // A link's `net.node` while it waits (no node key yet) leaves the sign-in as it is.
        join.node(on: true, nodeKey: nil, sidecar: true)
        #expect(join.ending == .signIn && join.fix == .signIn(Self.page))
    }

    /// Without the helper: today's lines on Linux, a Mac's own on a Mac.
    @Test func withoutKoresOwnEachSystemSaysItsOwn() {
        let missing = HostUpgrade.Tailscale.kore(.unavailable(BoxTailnet.noHelper))
        #expect(outcome(missing, os: .linux) == .failed("Install Tailscale on mybox", .copy(BoxNetJoin.installLine)))
        #expect(outcome(missing, os: .macos) == .failed(BoxNetJoin.installMacLine("mybox"), nil))
    }

    /// Installed Tailscale stopped or signed out: Linux keeps its sudo line, a Mac opens Tailscale.
    @Test func installedButOffSaysEachSystemsWay() {
        #expect(outcome(.stopped(.stopped, login: nil), os: .linux) == .tailscaleOff(macOS: false, line: BoxNetJoin.sudoLine))
        #expect(outcome(.notRunning, os: .linux) == .tailscaleOff(macOS: false, line: HostUpgrade.daemonLine))
        #expect(outcome(.stopped(.needsLogin, login: Self.page), os: .linux) == .signIn(page: Self.page, kore: false))
        for seen in [HostUpgrade.Tailscale.stopped(.stopped, login: nil), .stopped(.needsLogin, login: Self.page), .notRunning, .denied] {
            #expect(outcome(seen, os: .macos) == .tailscaleOff(macOS: true, line: BoxNetJoin.openLine("mybox")))
        }
        let join = BoxNetJoin(key: "mybox", name: "mybox")
        join.started(version: "0.2.3")
        let report = report(.stopped(.stopped, login: nil), os: .macos, listen: "not listening")
        join.take(BoxNetJoin.outcome(report, name: "mybox", macAccount: nil), report: report)
        #expect(join.ending == .needsSudo && join.fix == nil && join.line == "Open Tailscale on mybox and sign in")
    }

    /// No Linux line ever reaches a Mac box, whatever its tailnet says.
    @Test func aMacBoxNeverGetsALinuxLine() {
        let all: [HostUpgrade.Tailscale] = [
            .stopped(.stopped, login: nil), .stopped(.needsLogin, login: Self.page), .stopped(.noState, login: nil), .notRunning, .absent, .denied,
            .kore(.signIn(Self.page)), .kore(.signIn(nil)), .kore(.unavailable("x")), .running(node: "n", account: "other@example.com"),
        ]
        for seen in all {
            let words: String = switch outcome(seen, os: .macos) {
            case .link: ""
            case .signIn(let page, _): page
            case .tailscaleOff(_, let line): line
            case .failed(let why, let fix): why + " " + (fix.map { "\($0)" } ?? "")
            }
            for linux in ["sudo", "curl", "systemctl", "install.sh"] { #expect(!words.contains(linux), "\(seen): \(words)") }
        }
    }

    /// D: the box's tailnet signed in as someone other than this Mac: said, with one action.
    @Test func anotherAccountIsSaidWithOneAction() {
        let line = BoxNetJoin.accountLine("mybox")
        #expect(line == "mybox is on a different Tailscale account")
        #expect(outcome(.kore(.running(node: "k", account: "else@example.com")), os: .linux) == .failed(line, .relogin))
        #expect(outcome(.kore(.running(node: "k", account: "else@example.com")), os: .macos) == .failed(line, .relogin))
        #expect(outcome(.running(node: "k", account: "else@example.com"), os: .linux) == .failed(line, .copy(BoxNetJoin.loginLine)))
        #expect(outcome(.running(node: "k", account: "else@example.com"), os: .macos) == .failed(line, nil))
        // This Mac's own account unknown (its tailnet's users not read): never a guess.
        #expect(outcome(.running(node: "k", account: "else@example.com"), os: .linux, mac: nil) == .link)
        #expect(BoxFix.relogin.title == "Sign in again ↗")
        #expect(BoxUpgradeShell.line(command: "kore-host", grant: "MacBook", want: nil, relogin: true) == "kore-host upgrade --grant 'MacBook' --relogin")
    }

    /// The status a Mac reads names its own account.
    @Test func theTailnetSaysWhoItIsSignedInAs() throws {
        let json = #"{"BackendState":"Running","Self":{"PublicKey":"nodekey:m","TailscaleIPs":["100.64.0.1"],"UserID":5},"User":{"5":{"ID":5,"LoginName":"owner@example.com"},"9":{"ID":9,"LoginName":"x@example.com"}}}"#
        let status = try JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
        #expect(status.login == "owner@example.com")
    }

    /// The row with no run to say it: a Mac box or Kore's own tailnet off gets no sudo line.
    @Test func aRowsOffLineFollowsTheBox() {
        func row(os: String?, tailnet: String?) -> DeviceRow? {
            var entry = NodeDirectory.Entry(device: UUID(), name: "mybox", ssh: "mybox", nodeKey: nil, identityKey: Data([1]), enrolled: true, on: true)
            entry.os = os
            entry.tailnet = tailnet
            var facts = BoxFacts(key: "mybox", name: "mybox")
            facts.entry = entry
            facts.online = true
            facts.route = .ssh(alias: "mybox", grant: "mac")
            let net = NetFacts(on: true, state: .installed, status: TailnetStatus(backendState: .running, selfNode: .init(publicKey: "nodekey:m", tailscaleIPs: ["100.64.0.1"], userID: 5)))
            return DevicesPicture.make(net: net, macName: "MacBook", boxes: [facts], phones: [], addUntil: nil, refusals: [], signingIn: false, nudge: false, now: Date()).devices.first
        }
        let linux = row(os: "linux", tailnet: "tailscale")
        #expect(linux?.upgradeFix == .copy(BoxNetJoin.sudoLine) && linux.flatMap { DevicesWords.detail($0, now: Date()) } == "Tailscale is off on mybox")
        let mac = row(os: "macos", tailnet: "tailscale")
        #expect(mac?.upgradeFix == nil && mac.flatMap { DevicesWords.detail($0, now: Date()) } == "Open Tailscale on mybox and sign in")
        let kore = row(os: "linux", tailnet: "kore")
        #expect(kore?.upgradeFix == nil && kore.flatMap { DevicesWords.detail($0, now: Date()) } == "Sign in for mybox")
    }

    /// The box says its system and tailnet in `net.node`; the directory keeps them.
    @Test func theDirectoryKeepsTheBoxsSystem() {
        let node = NetNodeWire.Node(device: UUID(), identityKey: Data([1]), name: "mybox", on: true, os: "macos", tailnet: "kore")
        let heard = NodeDirectory.heard(node, before: nil, ssh: "mybox")
        #expect(heard.entry.macOS && heard.entry.tailnet == "kore")
        let older = NetNodeWire.Node(device: node.device, identityKey: Data([1]), name: "mybox", on: true)
        #expect(NodeDirectory.heard(older, before: heard.entry, ssh: "mybox").entry.macOS, "a box that didn't say kept what it said before")
    }
}
