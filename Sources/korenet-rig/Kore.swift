// Kore.app without its UI: the same objects `NetLiveness.start` makes, the same way, over the
// rig's ssh and tailnets. What a scenario reads back is what the Devices popup and the box
// window would show (`DevicesPicture`, the link's route and phase).
#if os(macOS)
import Foundation
import HostClient
import KoreCore
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet

@MainActor
final class Kore {
    let places: RigPlaces
    let browser = Browser()
    let macTailscale: MacTailscale
    let support: URL
    private(set) var net: KoreNetSwitch!
    /// Box windows open now (each holds its link).
    private(set) var windows: [String: HostConnection] = [:]

    init(places: RigPlaces, macTailscale: MacTailscale) {
        self.places = places
        self.macTailscale = macTailscale
        // This process's folders under the scratch (never the owner's Kore's).
        let base = ProcessInfo.processInfo.environment["RIG_KORE_BASE"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? places.scratch.appendingPathComponent("kore", isDirectory: true)
        KoreFolders.place(KoreFolders.Places(under: base))
        support = KoreFolders.support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    /// Kore launches with KoreNet on (`NetLiveness.start`, then the Devices switch).
    func launch() {
        SSHTransport.ssh = places.sshWrapper.path
        SSHTransport.scp = places.scpWrapper.path
        let defaults = UserDefaults.standard
        defaults.set(places.hostBin.path, forKey: BoxBinary.overrideKey)
        let mac = macTailscale
        let places = places
        let support = support
        let env = NetEnvironment(
            installed: {
                let api = LocalAPIClient(discover: { mac.endpoint() })
                let (found, local) = TailnetChooser.installed(api)
                return (found, local.map { RigInstalled(local: $0 as! TailnetLocal, socket: mac.socket) })
            },
            sidecar: { key in
                let sidecar = try NetSidecar.start(
                    helper: places.macHelper, folder: places.scratch.appendingPathComponent("own", isDirectory: true), key: key, arguments: ["-hostname", "rig-mac-kore"])
                return (sidecar.tailnet, { sidecar.stop() })
            },
            secrets: FileSecrets(folder: FileSecrets.folder(support: support)), defaults: defaults, support: support,
            upgradeDial: { alias, grant, command in
                let (mine, theirs) = try Sockets.pair()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: SSHTransport.ssh)
                process.arguments = SSHTransport.arguments(alias: alias, grant: grant, command: command) + ["--proto", "2"]
                let handle = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
                process.standardInput = handle
                process.standardOutput = handle
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    Sockets.closeFD(mine)
                    Sockets.closeFD(theirs)
                    throw error
                }
                Sockets.closeFD(theirs)
                return (mine, { if process.isRunning { process.terminate() } })
            },
            macName: { "rig-mac" },
            watchRunning: { changed in mac.watch(changed) })
        let net = KoreNetSwitch(defaults: defaults, directory: .shared, rekeyer: NodeRekeyer(migration: NodeMigration()), environment: { env })
        KoreNetSwitch.shared = net
        let browser = browser
        BoxUpgrades.shared.openURL = { browser.open($0) }
        net.upgrades = BoxUpgrades.shared
        HostConnection.sshNet = net
        BoxList.shared.cacheRoot = support.appendingPathComponent("hosts", isDirectory: true)
        BoxList.shared.reload()
        self.net = net
        net.start()
        net.set(true)
        followMacSignIn()
    }

    /// "Sign in to Kore's tailnet" on this Mac, pressed when its line asks (once per page).
    /// As `Devices.signIn`: the bus held while it waits, the page opened once when it comes.
    var macSignsIn = true
    private func followMacSignIn() {
        Task { [weak self] in
            var opened: Set<String> = []
            var holding = false
            while let self {
                let facts = self.net.facts
                let wants = facts.on && (facts.state == .sidecar ? facts.status?.backendState != .running : facts.ownSignIn != nil)
                if wants, self.macSignsIn, !holding {
                    holding = true
                    self.net.hold("signin", true)
                    self.net.readStatus()
                } else if !wants, holding {
                    holding = false
                    self.net.hold("signin", false)
                }
                if holding, let page = self.net.authURL, page.hasPrefix("https://"), !opened.contains(page), let url = URL(string: page) {
                    opened.insert(page)
                    self.browser.open(url)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: Boxes

    /// Add a box… → Set up, as the box card's button runs it; the list's status after.
    func addAndSetUp(_ alias: String) async -> BoxList.Status? {
        BoxList.shared.add(alias)
        await BoxList.shared.setUp(alias)
        return BoxList.shared.box(alias)?.status
    }

    /// The box's window opens: it holds the link.
    @discardableResult
    func open(_ key: String) -> HostConnection {
        if let held = windows[key] { return held }
        let link = BoxList.shared.link(key)
        link.retain()
        // On screen, as an owner's window is (its link checked on the beat while it shows).
        link.onScreen("window", true)
        windows[key] = link
        return link
    }

    /// The box's window leaves the screen (hidden, minimised, covered) or comes back.
    func show(_ key: String, _ shown: Bool) { link(key)?.onScreen("window", shown) }

    func close(_ key: String) {
        guard let link = windows.removeValue(forKey: key) else { return }
        link.onScreen("window", false)
        link.release()
    }

    /// The box's link now, by whichever key it goes by (its alias moves to its id on KoreNet).
    func link(_ alias: String) -> HostConnection? {
        if let held = windows[alias], HostConnection.current(alias) == alias { return held }
        return HostConnection.live(HostConnection.current(alias)) ?? HostConnection.live(alias) ?? windows[alias]
    }

    func entry(_ alias: String) -> NodeDirectory.Entry? {
        NodeDirectory.shared.entry(forKey: alias) ?? NodeDirectory.shared.all.values.first { $0.ssh == alias }
    }

    // MARK: What the owner sees

    /// The box's Devices row: its status and the line under its name.
    func row(_ alias: String) -> (status: DeviceRow.Status, line: String)? {
        let picture = self.picture()
        let names = Set([alias, HostConnection.current(alias), entry(alias)?.id.raw].compactMap { $0 })
        guard let row = picture.devices.first(where: { names.contains($0.id) }) else { return nil }
        return (row.status, DevicesWords.detail(row, now: Date()) ?? "")
    }

    /// This Mac's own row line (the popup's first line).
    func macLine() -> String { DevicesWords.macDetail(picture()) }

    func picture() -> DevicesPicture {
        let directory = NodeDirectory.shared
        let list = BoxList.shared
        let boxes = DevicesPicture.boxKeys(listed: list.boxes.map(\.alias), entries: Array(directory.all.values)).map { box in
            facts(box.key, box.listed.flatMap(list.box), directory)
        }
        return DevicesPicture.make(net: net.facts, macName: "rig-mac", boxes: boxes, phones: [], addUntil: nil, refusals: [], signingIn: false, nudge: false, now: Date())
    }

    /// As `Devices.facts` (KoreUI) gathers them.
    private func facts(_ key: String, _ box: BoxList.Box?, _ directory: NodeDirectory) -> BoxFacts {
        var facts = BoxFacts(key: key, name: NodeNames.name(key))
        let connection = HostConnection.live(key) ?? box.flatMap { $0.alias == key ? nil : HostConnection.live($0.alias) }
        facts.listed = box?.status
        facts.older = box?.older == true || connection?.hostOlder == true
        facts.online = connection?.isOnline ?? false
        facts.route = connection?.route
        facts.lastHeard = connection?.lastHeard
        if case .refused(let why)? = connection?.phase { facts.refused = why }
        facts.entry = directory.entry(forKey: key)
        facts.paused = NetPauses.shared.contains(key)
        facts.ownStep = BoxOwnFollow.shared.line(key) ?? facts.entry.flatMap { BoxOwnFollow.shared.line($0.id.raw) }
        facts.pending = connection?.pendingDevices ?? facts.entry?.pending ?? []
        facts.upgrade = BoxUpgrades.shared.facts(key)
        facts.update = BoxUpdates.shared.work[connection?.alias ?? key]
        return facts
    }

    /// One line of state for the log: route, phase, the row.
    func describe(_ alias: String) -> String {
        let link = self.link(alias)
        let route = link?.route.map { $0.isNet ? "net" : "ssh" } ?? "-"
        let row = self.row(alias).map { "\($0.status) · \($0.line)" } ?? "no row"
        return "mac=\(net.state) route=\(route) online=\(link?.isOnline == true) row=\(row)"
    }

    /// `ssh <alias> true` as Kore runs it (Set up's shell: the alias, plus `SSHTailnetRoute`).
    func sshThroughKore(_ alias: String, _ command: String = "true") async -> Ran {
        // As Set up's shell runs it, bounded (a stuck ssh is a failure here, never a hang).
        let ran = await BoxShell().script(alias, command + "\n", limit: .seconds(30))
        return Ran(status: ran.status, out: ran.output)
    }

    // MARK: Over the link

    /// `fs.list` of a folder on the box, over whatever route the link has.
    func list(_ alias: String, _ path: String) async -> Bool {
        guard let link = link(alias) else { return false }
        let result = await link.command { id in
            (try? JSONSerialization.data(withJSONObject: ["t": "cmd", "id": id, "cmd": ["type": "fs.list", "path": path]], options: [.sortedKeys])) ?? Data()
        }
        return result.ok
    }

    /// A chat made on the box (no CLI runs) and a `chat.call` on it (`setDraft`).
    func chatCall(_ alias: String, folder: String) async -> String? {
        guard let link = link(alias) else { return "no link" }
        _ = await link.addFolder(folder)
        let made = await link.command { id in
            (try? JSONSerialization.data(withJSONObject: ["t": "cmd", "id": id, "cmd": ["type": "chat.new", "folder": folder, "provider": "claude"]], options: [.sortedKeys])) ?? Data()
        }
        guard made.ok, let chat = made.chatId else { return "chat.new: \(made.message ?? "no chat")" }
        let call = await link.call(chat, .setDraft("korenet-rig \(UUID().uuidString.prefix(6))"))
        return call.ok ? nil : "chat.call: \(call.message ?? "refused")"
    }
}
#endif
