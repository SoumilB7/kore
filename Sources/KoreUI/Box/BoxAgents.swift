import AppKit
import HostClient
import src
import SwiftUI

/// The box row's one popup: a line per agent (claude, codex, gh) with its one action (Install,
/// Sign in), then what else differs from this Mac, each with its safe fix (Update, Use mine,
/// Copy) or listed only (MCP servers, skills: they can carry secrets, so nothing is copied).
/// Opened from the row's line or its menu; one Kore popup at a time, in the window, closed by a
/// click outside or Esc.
@MainActor
final class BoxCard {
    static let shared = BoxCard()
    private var host: NSView?
    private weak var owner: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var origin = CGPoint.zero

    /// The agents popup for `alias`, under `anchor`.
    func showAgents(_ alias: String, under anchor: NSView?) {
        guard let anchor, let window = anchor.window, let content = window.contentView else { return }
        close()
        OptionsMenu.shared.close()
        owner = window
        let below = anchor.convert(CGPoint(x: anchor.bounds.minX, y: anchor.isFlipped ? anchor.bounds.maxY : anchor.bounds.minY), to: nil)
        origin = content.convert(below, from: nil)
        let host = NSHostingView(rootView: BoxAgentsView(alias: alias) { [weak self] size in self?.place(size) } close: { [weak self] in self?.close() })
        self.host = host
        content.addSubview(host)
        place(host.fittingSize)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let host = self.host else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window !== self.owner || !host.bounds.contains(host.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    private func place(_ size: CGSize) {
        guard let host, let content = owner?.contentView else { return }
        let size = CGSize(width: Size.Box.agentsWidth, height: max(size.height, 1))
        host.frame = OptionsMenu.fitting(point: origin, size: size, bounds: content.bounds, flipped: content.isFlipped)
    }

    func close() {
        host?.removeFromSuperview()
        host = nil
        owner = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

/// An NSView under a SwiftUI view, handed to `set`, for placing a popup by it.
struct BoxAnchor: NSViewRepresentable {
    let set: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        set(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { set(view) }
}

/// What the agents popup shows: the agents, the differences, and Check again.
struct BoxAgentsView: View {
    let alias: String
    let resized: (CGSize) -> Void
    let close: () -> Void
    @StateObject private var connection = Local<HostConnection?>(nil)
    /// An agent's install under way, or why it failed: by agent or difference id.
    @StateObject private var working = Local<[String: String]>([:])
    @StateObject private var failed = Local<[String: BoxSetup.Failure]>([:])
    @StateObject private var checking = Local(false)

    private var list: BoxList { .shared }

    var body: some View {
        let box = list.box(alias)
        let machine = box?.machine
        VStack(alignment: .leading, spacing: Space.sm) {
            // The one essential line: what the machine is.
            Text(machine?.kind ?? NodeNames.name(alias)).font(Chrome.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            ForEach(BoxAgent.allCases, id: \.self) { agent in agentLine(agent, machine: machine) }
            let rest = differences(box?.parity)
            if !rest.isEmpty {
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
                ForEach(rest) { difference in differenceLine(difference) }
            }
            HStack {
                Spacer(minLength: 0)
                Button(checking.value ? "Checking…" : "Check again") { Task { await check() } }.smallButton().disabled(checking.value)
            }
        }
        .padding(Space.md)
        .frame(width: Size.Box.agentsWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .onAppear {
            let link = list.link(alias)
            link.retain()
            connection.value = link
            Task { await readLogins() }
        }
        .onDisappear {
            connection.value?.release()
            connection.value = nil
        }
    }

    // MARK: Agents

    @ViewBuilder private func agentLine(_ agent: BoxAgent, machine: BoxMachine?) -> some View {
        let installed = machine?.has(agent.rawValue) == true
        if installed, let accounts = connection.value?.accounts {
            BoxAccountLine(title: agent.rawValue, key: agent.account, accounts: accounts, takesPaste: agent == .claude) {
                agent == .gh ? accounts.signInGitHub() : accounts.signIn(agent.rawValue)
            }
        } else {
            let key = "agent." + agent.rawValue
            HStack(spacing: Space.sm) {
                Text(agent.rawValue).font(TextStyle.labelMedium).foregroundStyle(Theme.text)
                Text(working.value[key] ?? failed.value[key]?.message ?? (machine == nil ? "Checking…" : "not installed"))
                    .font(TextStyle.caption).foregroundStyle(failed.value[key] == nil ? Theme.secondary : Theme.danger).lineLimit(2)
                Spacer(minLength: Space.sm)
                if working.value[key] == nil, machine != nil {
                    if case .copy(let command)? = failed.value[key]?.fix {
                        CopyButton(text: command)
                    } else {
                        Button("Install") { install(agent, key: key) }.smallButton(prominent: true)
                    }
                }
            }
        }
    }

    private func install(_ agent: BoxAgent, key: String) {
        working.value[key] = "Installing…"
        failed.value[key] = nil
        Task {
            let why = await list.install(agent, on: alias)
            working.value[key] = nil
            failed.value[key] = why
            if why == nil { await readLogins() }
        }
    }

    // MARK: Differences

    /// The differences the agent lines don't already say (a missing CLI, a login).
    private func differences(_ parity: BoxParity?) -> [BoxParity.Difference] {
        (parity?.differences ?? []).filter { difference in
            !(difference.id.hasPrefix("login.") || BoxAgent.allCases.contains { difference.id == "tool." + $0.rawValue })
        }
    }

    private func differenceLine(_ difference: BoxParity.Difference) -> some View {
        HStack(spacing: Space.sm) {
            Text(failed.value[difference.id]?.message ?? difference.line)
                .font(TextStyle.caption).foregroundStyle(failed.value[difference.id] == nil ? Theme.secondary : Theme.danger).lineLimit(2)
            Spacer(minLength: Space.sm)
            if let busy = working.value[difference.id] {
                Text(busy).font(TextStyle.caption).foregroundStyle(Theme.tertiary)
            } else if let fix = difference.fix {
                switch fix {
                case .install(let agent): Button("Update") { install(agent, key: difference.id) }.smallButton()
                case .gitIdentity(let name, let email):
                    Button("Use mine") { fixGit(name: name, email: email, key: difference.id) }.smallButton()
                case .tool(let tool): Button("Install") { fixTool(tool, key: difference.id) }.smallButton()
                case .copy(let command): CopyButton(text: command)
                case .signIn: EmptyView()
                }
            }
        }
    }

    private func fixGit(name: String?, email: String?, key: String) {
        working.value[key] = "Setting…"
        Task {
            failed.value[key] = await list.setGitIdentity(name: name, email: email, on: alias)
            working.value[key] = nil
        }
    }

    private func fixTool(_ tool: String, key: String) {
        working.value[key] = "Installing…"
        Task {
            failed.value[key] = await list.installTool(tool, on: alias)
            working.value[key] = nil
        }
    }

    // MARK: Logins

    /// Each side's logins, then the compare again with them.
    private func readLogins(refresh: Bool = false) async {
        guard let accounts = connection.value?.accounts, let machine = list.box(alias)?.machine else { return }
        var boxLogins: [String: BoxLogin] = [:]
        for agent in [BoxAgent.claude, .codex] where machine.has(agent.rawValue) {
            await accounts.refresh(agent.rawValue)
            if let login = BoxLogin.said(accounts.line(agent.rawValue)) { boxLogins[agent.rawValue] = login }
        }
        if let gh = BoxLogin.said(accounts.line(BoxAccounts.gitHub)) { boxLogins[BoxAccounts.gitHub] = gh }
        var macLogins: [String: BoxLogin] = [:]
        for cli in ["claude", "codex"] {
            switch AccountStore.shared.status(cli) {
            case .signedIn(let identity): macLogins[cli] = BoxLogin(signedIn: true, who: identity.email)
            case .signedOut: macLogins[cli] = BoxLogin(signedIn: false)
            default: break
            }
        }
        await list.compare(alias, macLogins: macLogins, boxLogins: boxLogins, refresh: refresh)
    }

    private func check() async {
        checking.value = true
        failed.value = [:]
        await list.detect(alias)
        await readLogins(refresh: true)
        checking.value = false
    }
}

/// Copy, for a command the user runs in their own Terminal; "Copied" for a moment after.
struct CopyButton: View {
    let text: String
    @StateObject private var copied = Local(false)

    var body: some View {
        Button(copied.value ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied.value = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied.value = false
            }
        }
        .smallButton()
    }
}
