import AppKit
import Foundation
import HostClient
import KoreTrust
import SwiftUI
import Tailnet
import Testing

@testable import KoreUI

/// KoreNet's surfaces against korenet-first-connect.html, drawn in-process from scripted sides, as
/// PNGs to look at: set `KORE_NET_SNAPSHOTS` to a folder. No keys, no pointer, no tailnet.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KORE_NET_SNAPSHOTS"] != nil))
struct NetSnapshotTests {
    private var folder: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["KORE_NET_SNAPSHOTS"] ?? "/tmp") }

    private func shoot(_ name: String, _ view: some View, size: CGSize, settle: Duration = .milliseconds(150)) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading).padding(Space.md).background(Color.black).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 2 * Space.md, height: size.height + 2 * Space.md))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }

    static func status(_ state: BackendState = .running, peers: String = "", selfExtra: String = "", health: String = "[]") -> TailnetStatus {
        let json = #"{"BackendState":"\#(state.rawValue)","Self":{"PublicKey":"nodekey:mac","TailscaleIPs":["100.64.0.1"],"UserID":7,"HostName":"macbook"\#(selfExtra)},"Peer":{\#(peers)},"Health":\#(health)}"#
        return try! JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
    }

    static func box(_ key: String, online: Bool = true, route: HostRoute? = .net, nodeKey: String? = nil, listed: BoxList.Status = .ready) -> BoxFacts {
        var facts = BoxFacts(key: key, name: key)
        facts.listed = listed
        facts.online = online
        facts.route = online ? route : nil
        if let nodeKey { facts.entry = NodeDirectory.Entry(device: UUID(), name: key, ssh: key, nodeKey: nodeKey, identityKey: Data([1]), enrolled: true) }
        return facts
    }

    /// Devices over scripted sides; restored after.
    func with(_ net: ScriptedNet, phones: ScriptedPhones = ScriptedPhones(), boxes: [BoxFacts] = [], _ body: () async throws -> Void) async rethrows {
        let devices = Devices.shared
        devices.net = net
        devices.phones = phones
        devices.boxes = { boxes }
        devices.macNameOverride = "MacBook"
        defer {
            devices.net = nil
            devices.phones = nil
            devices.boxes = nil
            devices.macNameOverride = nil
        }
        devices.changed()
        try await body()
    }

    /// The title row's end: the network icon left of the clock.
    struct Bar: View {
        var body: some View {
            HStack(spacing: Size.tabGap) {
                Spacer(minLength: 0)
                NetworkButton(size: Size.tab)
                Image(systemName: "clock").font(Chrome.bodyMedium).foregroundStyle(Theme.secondary).frame(width: Size.tab, height: Size.tab)
            }
            .frame(height: Size.titleRow)
            .background(Theme.background)
        }
    }

    @Test func iconStates() async throws {
        let iconSize = CGSize(width: 200, height: 40)
        try await with(ScriptedNet()) { try await shoot("a1-0-off", Bar(), size: iconSize) }
        let peer = #""a":{"PublicKey":"nodekey:box","HostName":"mybox","TailscaleIPs":["100.64.0.9"],"Online":true,"UserID":7,"OS":"linux","CurAddr":"1.2.3.4:41641"}"#
        let phone = PhoneFacts(id: UUID(), name: "Pixel 9", connected: true, presence: "deploy fix")
        let phones = ScriptedPhones()
        phones.phones = [phone]
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status(peers: peer)), phones: phones, boxes: [Self.box("mybox", nodeKey: "nodekey:box")]) {
            try await shoot("a1-1-all-connected", Bar(), size: iconSize)
        }
        var down = Self.box("mybox", online: false, nodeKey: "nodekey:box")
        down.lastHeard = Date().addingTimeInterval(-7300)
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status()), boxes: [down]) { try await shoot("a1-2-one-offline", Bar(), size: iconSize) }
        var waiting = Self.box("mybox", nodeKey: "nodekey:box")
        waiting.pending = [Self.pending("Pixel 9", ago: 180)]
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status()), boxes: [waiting]) { try await shoot("a1-3-pending", Bar(), size: iconSize) }
        try await with(ScriptedNet(on: true, state: .stopped, status: Self.status(.stopped))) { try await shoot("a1-4-tailscale-off", Bar(), size: iconSize) }
    }

    static func pending(_ name: String, ago: TimeInterval, kind: NodeKind = .phone) -> PendingDevice {
        PendingDevice(
            nodeKey: "nodekey:" + name, device: UUID(), name: name, kind: kind, identityKey: Data([2]), userId: 7, tags: [], fqdn: name.lowercased() + ".ts.net.",
            login: "soumil@github", at: Date().addingTimeInterval(-ago))
    }

    @Test func popupStates() async throws {
        let size = CGSize(width: 300, height: 260)
        let net = { ScriptedNet(on: true, state: .installed, status: Self.status()) }
        try await with(ScriptedNet()) { try await shoot("a2-0-off", DevicesPopup(), size: size) }
        try await with(net()) { try await shoot("a2-1-empty", DevicesPopup(), size: size) }
        let phones = ScriptedPhones()
        phones.phones = [PhoneFacts(id: UUID(), name: "Pixel 9", connected: true, presence: "deploy fix")]
        try await with(net(), phones: phones, boxes: [Self.box("mybox", nodeKey: "k")]) { try await shoot("a2-2-mac-box-phone", DevicesPopup(), size: size) }
        let away = ScriptedPhones()
        away.phones = [PhoneFacts(id: UUID(), name: "Pixel 9", connected: false, lastSeen: Calendar.current.date(bySettingHour: 0, minute: 2, second: 0, of: Date()))]
        var down = Self.box("mybox", online: false, nodeKey: "k")
        down.lastHeard = Date().addingTimeInterval(-7300)
        try await with(net(), phones: away, boxes: [down]) { try await shoot("a2-3-offline-rows", DevicesPopup(), size: size) }
        let relayPeer = #""a":{"PublicKey":"k3","HostName":"box-3","TailscaleIPs":["100.64.0.9"],"Online":true,"UserID":7,"OS":"linux","Relay":"fra"}"#
        try await with(
            ScriptedNet(on: true, state: .installed, status: Self.status(peers: relayPeer)),
            boxes: [Self.box("mybox", nodeKey: "k"), Self.box("box-1", route: .ssh(alias: "box-1", grant: "m")), Self.box("box-3", nodeKey: "k3")]
        ) { try await shoot("a2-4-routes", DevicesPopup(), size: size) }
        let adding = ScriptedPhones()
        adding.addUntil = Date().addingTimeInterval(600)
        try await with(net(), phones: adding, boxes: [Self.box("mybox", nodeKey: "k")]) { try await shoot("a2-5-add-window", DevicesPopup(), size: size) }
        adding.addUntil = Date().addingTimeInterval(431)
        adding.refusals = [DeviceRefusal(name: "ci-runner", tag: "tag:ci")]
        try await with(net(), phones: adding) { try await shoot("a2-6-add-refused", DevicesPopup(), size: size) }
        var waiting = Self.box("mybox", nodeKey: "k")
        waiting.pending = [Self.pending("Pixel 9", ago: 180), Self.pending("box-4", ago: 540, kind: .box)]
        try await with(net(), boxes: [waiting]) { try await shoot("a2-7-pending", DevicesPopup(), size: size) }
    }

    @Test func firstConnection() async throws {
        let size = CGSize(width: 300, height: 200)
        let ssh = Self.box("mybox", route: .ssh(alias: "mybox", grant: "m"))
        let phones = ScriptedPhones()
        phones.phones = [PhoneFacts(id: UUID(), name: "Pixel 9", connected: false)]
        try await with(ScriptedNet(on: true, state: .stopped, status: Self.status(.stopped)), phones: phones, boxes: [ssh]) {
            try await shoot("c2-stopped", VStack(spacing: Space.md) { Bar(); DevicesPopup() }, size: CGSize(width: 300, height: 260))
        }
        try await with(ScriptedNet(on: true, state: .signedOut, status: Self.status(.needsLogin))) { try await shoot("c2-signed-out", DevicesPopup(), size: size) }
        let notJoined = ScriptedNet(on: true, state: .sidecar, status: Self.status(.needsLogin), authURL: "https://login.tailscale.com/a/1f2e")
        try await with(notJoined) { try await shoot("c3a-not-joined", VStack(spacing: Space.md) { Bar(); DevicesPopup() }, size: CGSize(width: 300, height: 200)) }
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status())) { try await shoot("c1-running", DevicesPopup(), size: size) }
        let expiring = Self.status(
            peers: #""a":{"PublicKey":"k","HostName":"mybox","TailscaleIPs":["100.64.0.9"],"Online":true,"UserID":7,"OS":"linux","CurAddr":"1.2.3.4:1","KeyExpiry":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 86400 + 600)))"}"#,
            selfExtra: #","KeyExpiry":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400 + 600)))""#)
        try await with(ScriptedNet(on: true, state: .installed, status: expiring), boxes: [Self.box("mybox", nodeKey: "k")]) { try await shoot("c4-key-expiring", DevicesPopup(), size: size) }
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status(health: #"["this node is locked out; it will not have connectivity until it is signed"]"#))) {
            try await shoot("c-lock", DevicesPopup(), size: size)
        }
    }

    @Test func cards() async throws {
        let size = CGSize(width: 300, height: 230)
        let phone = DeviceCardInfo.phone(name: "Pixel 9", node: "pixel-9", address: "100.101.7.22", login: "soumil@github", firstSeen: Date())
        try await shoot("b1-phone-unarmed", DeviceCardView(state: DeviceCardState(phone), answer: { _ in }, close: {}), size: size)
        let armed = DeviceCardState(phone)
        armed.armed = true
        try await shoot("b2-phone-armed", DeviceCardView(state: armed, answer: { _ in }, close: {}), size: size)
        let box = DeviceCardState(.box(name: "box-2", node: "box-2", address: "100.88.14.3", login: "soumil@github", firstSeen: Date().addingTimeInterval(-40), device: UUID(uuidString: "7F3A91C2-0000-4000-8000-000000000000")))
        box.armed = true
        try await shoot("b3-box-claim", DeviceCardView(state: box, answer: { _ in }, close: {}), size: CGSize(width: 300, height: 250))
        let stopped = DeviceCardState(phone)
        stopped.stopped = true
        try await shoot("b4-stopped", DeviceCardView(state: stopped, answer: { _ in }, close: {}), size: CGSize(width: 300, height: 120))
    }

    @Test func joinSheets() async throws {
        let size = CGSize(width: 340, height: 220)
        func sheet(_ path: ScriptedJoin.Path, steps: Int, _ more: (BoxNetJoin) -> Void = { _ in }) -> NetJoinSheet {
            let runner = ScriptedJoin(path)
            let join = BoxNetJoin(key: "mybox-\(path)-\(steps)", name: "mybox")
            runner.start(join)
            for _ in 0..<steps { runner.advance(join) }
            more(join)
            return NetJoinSheet(join: join)
        }
        try await shoot("d2-a-reaching", sheet(.usual, steps: 1), size: size)
        try await shoot("d2-b-sign-in", sheet(.signIn, steps: 1), size: size)
        try await shoot("d2-c-done", sheet(.usual, steps: 2), size: size)
        try await shoot("d2-no-sudo", sheet(.noSudo, steps: 1), size: size)
        try await shoot("d2-relayed", sheet(.relayed, steps: 2), size: size)
        try await shoot("d2-cancelled", sheet(.signIn, steps: 1) { $0.signInCancelled() }, size: size)
        try await shoot("d3-unreachable", sheet(.unreachable, steps: 2), size: size)
    }

    @Test func welcomeAdd() async throws {
        let claims = ScriptedClaims()
        claims.listed = [ClaimPeer(name: "box-2", address: "100.88.14.3", nodeKey: "k2", login: "soumil@github")]
        Devices.shared.claims = claims
        defer { Devices.shared.claims = nil }
        try await shoot("d1-1-plus-list", WelcomeAddList(useSSH: {}, newBox: {}, ready: { _ in }), size: CGSize(width: 220, height: 130))
        let phones = ScriptedPhones()
        phones.addUntil = Date().addingTimeInterval(582)
        try await with(ScriptedNet(on: true, state: .installed, status: Self.status()), phones: phones) {
            try await shoot("d1-2-new-box", NewBoxPopup(ready: { _ in }), size: CGSize(width: 340, height: 140))
        }
    }
}
