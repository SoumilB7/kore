import Foundation
import HostClient
import LinkProtocol
import Testing

/// What a box is, how it's named, what it lacks next to this Mac, and how its agents go on.
@MainActor
@Suite(.serialized)
struct BoxMachineTests {
    private func machine(_ kind: FakeSSH.Kind) throws -> BoxMachine { try #require(BoxMachine.parse(kind.detection)) }

    // MARK: Detection

    @Test func eachKindOfMachineReadsAsItIs() throws {
        let debian = try machine(.linuxSystemd)
        #expect(debian.kind == "Linux · x86_64 · Debian GNU/Linux 13 (trixie)")
        #expect(debian.platform == "linux-x86_64")
        #expect(debian.service == "systemd")
        #expect(debian.missing("mybox") == nil)
        #expect(debian.gitEmail == "me@example.com")

        let alpine = try machine(.linuxNoSystemd)
        #expect(alpine.service == "on demand")
        #expect(alpine.missing("pod")?.line == "rsync isn't on pod · sync needs it")
        #expect(alpine.missing("pod")?.command == "sudo apk add rsync")
        #expect(!alpine.installsWithoutPassword("rsync"))

        let mac = try machine(.macOS)
        #expect(mac.kind == "macOS 15.2 · arm64")
        #expect(mac.platform == "macos-arm64")
        #expect(mac.service == "launchd")
        #expect(mac.installCommand("gh") == "brew install gh")
        #expect(mac.installsWithoutPassword("gh"))

        let pi = try machine(.aarch64)
        #expect(pi.kind == "Linux · arm64 · Ubuntu 24.04.1 LTS")
        #expect(pi.platform == "linux-aarch64")
        #expect(pi.installCommand("rsync") == "sudo apt-get install -y rsync")

        #expect(try machine(.oldMac).unsupported("mini") == "mini runs macOS 13.6 · Kore needs macOS 15 or later")
        #expect(BoxMachine.parse("uname=Linux riscv64\n")?.unsupported("v") == "v has a riscv64 CPU · Kore runs on x86_64 and arm64")
        #expect(BoxMachine.parse("uname=FreeBSD amd64\n")?.unsupported("f") == "f runs FreeBSD amd64 · Kore runs on Linux and macOS boxes")
        #expect(BoxMachine.parse("Permission denied") == nil)
        #expect(BoxMachine.parse("uname=Linux x86_64\nuid=0\nhas.apt-get=/usr/bin/apt-get\n")?.installCommand("rsync") == "apt-get install -y rsync")
    }

    @Test func theScriptOnlyReadsAndItsShallowFormRunsNoCLI() {
        let shallow = BoxMachine.script(deep: false)
        #expect(!shallow.contains("--version\" 2>&1 </dev/null"))
        #expect(!shallow.contains(" facts"))
        for word in ["install", "rm ", "mv ", "systemctl --user start", "enable", "> ", "tee"] { #expect(!shallow.contains(word)) }
        let deep = BoxMachine.script()
        #expect(deep.contains("for t in claude codex gh git node rsync"))
        #expect(deep.contains("\"$k\" facts"))
        // Run here, the same script says what this Mac is.
        let parsed = BoxMachine.parse("uname=Darwin arm64\nmacos=15.2\nv.claude=2.1.322\nfacts={\"claudeMCP\":[\"files\"],\"claudeAgents\":[],\"claudePlugins\":[],\"claudeSkills\":[],\"codexMCP\":[]}\n")
        #expect(parsed?.versions["claude"] == "2.1.322")
        #expect(parsed?.facts?.claudeMCP == ["files"])
        #expect(BoxMachine.majorMinor("git version 2.47.1") == "2.47")
        #expect(BoxMachine.majorMinor("v22.11.0") == "22.11")
        #expect(BoxMachine.majorMinor("codex-cli 0.98.0") == "0.98")
        #expect(BoxMachine.majorMinor("none") == nil)
    }

    @Test func theShallowScriptRunsInAPlainShell() async throws {
        let ran = await BoxShell.local(BoxMachine.script(deep: false))
        let here = try #require(BoxMachine.parse(ran.output))
        #expect(here.system == .macOS)
        #expect(here.platform == BoxBinary.here)
        #expect(here.has("launchctl"))
    }

    // MARK: Destinations

    @Test func anyDestinationIsOneSafeWord() throws {
        let typed = try #require(BoxAddress("me@box.example.com:2222"))
        #expect(typed.user == "me")
        #expect(typed.host == "box.example.com")
        #expect(typed.port == 2222)
        #expect(typed.options == ["-o", "User=me", "-o", "Port=2222"])
        #expect(typed.command("ssh-copy-id") == "ssh-copy-id -p 2222 me@box.example.com")
        #expect(BoxAddress("mybox")?.options == [])
        #expect(BoxAddress("mybox")?.typed == false)
        #expect(BoxAddress("10.0.0.5")?.host == "10.0.0.5")
        #expect(BoxAddress(" pi@raspberrypi.local ")?.name == "pi@raspberrypi.local")
        for bad in [
            "-oProxyCommand=x", "a;b", "a b", "$(x)", "`x`", "a|b", "box:0", "box:99999", "box:", "@box", "me@", "me@-box", "a@b@c", "box:22:22",
            "[::1]", "a'b", "a\"b", "", "box/../x", "~box",
        ] {
            #expect(BoxAddress(bad) == nil, "\(bad)")
        }
        #expect(BoxList.alias("me@box:2200") == "me@box:2200")
        #expect(SyncBox.validAlias("me@box:2200"))
        // The link's ssh: the user and port as options, the host after `--`.
        #expect(SSHTransport.arguments(alias: "me@box:2200", grant: "mac").suffix(10) == ["-o", "User=me", "-o", "Port=2200", "--", "box", "~/.local/bin/kore-host", "attach", "--as", "mac"])
    }

    @Test func aTypedDestinationIsKeptInKoresListOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: "boxmachine-\(UUID().uuidString)"))
        let root = Fixture.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = BoxList(defaults: defaults, hosts: { ["mybox"] }, cacheRoot: root)
        list.add("me@10.0.0.5:2222")
        list.add("x;rm -rf ~")
        #expect(list.boxes.map(\.alias) == ["me@10.0.0.5:2222"])
        #expect(defaults.stringArray(forKey: "boxHosts") == ["me@10.0.0.5:2222"])
    }

    // MARK: The row's line

    @Test func aReadyBoxSaysWhatItLacksMostFirst() throws {
        var box = BoxList.Box(alias: "pod")
        box.status = .ready
        box.folders = [BoxFolder(path: "/srv")]
        box.machine = try machine(.linuxNoSystemd)
        #expect(box.note == .init(line: "No agents on pod yet", action: .setUpAgents))
        box.machine?.tools["codex"] = "/home/me/.local/bin/codex"
        #expect(box.note == .init(line: "rsync isn't on pod · sync needs it", action: .copy("sudo apk add rsync")))
        box.machine?.tools["rsync"] = "/usr/bin/rsync"
        box.parity = BoxParity(differences: [.init(id: "a", line: "a"), .init(id: "b", line: "b")])
        #expect(box.note == .init(line: "2 differences from this Mac", action: .differences(2)))
        box.parity = BoxParity()
        #expect(box.note == nil)
        box.status = .notSetUp
        box.machine = try machine(.oldMac)
        #expect(box.note == .init(line: "pod runs macOS 13.6 · Kore needs macOS 15 or later"))
        #expect(BoxFix.setUpAgents.title == "Set up agents")
        #expect(BoxFix.tryAgain.title == "Try again")
    }

    // MARK: Agents

    @Test func eachAgentInstallsUnderTheHomeWithoutSudo() throws {
        let debian = try machine(.linuxSystemd)
        let claude = try BoxAgent.claude.install(on: debian, name: "mybox").get()
        #expect(claude.contains("curl -fsSL https://claude.ai/install.sh"))
        // npm's there: the package under a user prefix. Without it: codex's own binary.
        let pi = try machine(.aarch64)
        #expect(try BoxAgent.codex.install(on: pi, name: "pi").get().contains("npm install -g --prefix \"$HOME/.npm-global\" @openai/codex"))
        let codex = try BoxAgent.codex.install(on: debian, name: "mybox").get()
        #expect(codex.contains("codex-x86_64-unknown-linux-musl.tar.gz"))
        #expect(codex.contains("\"$HOME/.local/bin/codex\""))
        #expect(try BoxAgent.gh.install(on: debian, name: "mybox").get().contains("gh_${v}_linux_amd64.tar.gz"))
        #expect(try BoxAgent.gh.install(on: machine(.macOS), name: "mini").get().contains("gh_${v}_macOS_universal.zip"))
        for script in [claude, codex] {
            #expect(!script.contains("sudo"))
            #expect(!script.lowercased().contains("api_key"))
        }
        // What's missing first, said with the command that adds it.
        let alpine = try machine(.linuxNoSystemd)
        if case .failure(let why) = BoxAgent.claude.install(on: alpine, name: "pod") {
            #expect(why == BoxSetup.Failure(message: "bash isn't on pod · claude's install needs it", fix: .copy("sudo apk add bash")))
        } else {
            Issue.record("claude without bash")
        }
    }

    @Test func installingAnAgentRunsItsScriptThereThenLooksAgain() async throws {
        let fake = try FakeSSH(.aarch64)
        defer { fake.finish() }
        let defaults = try #require(UserDefaults(suiteName: "boxmachine-\(UUID().uuidString)"))
        let list = BoxList(defaults: defaults, hosts: { [] }, cacheRoot: fake.root, setup: { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary())
        })
        list.findMac = { nil }
        list.add("pi")
        await list.detect("pi")
        #expect(list.box("pi")?.machine?.has("codex") == true)
        #expect(await list.install(.codex, on: "pi") == nil)
        #expect(await list.setGitIdentity(name: "Me Two", email: "me'2@example.com", on: "pi") == nil)
        #expect(fake.calls == [
            "ssh pi sh -s: # kore: detect", "ssh pi sh -s: npm install -g --prefix \"$HOME/.npm-global\" @openai/codex", "ssh pi sh -s: # kore: detect",
            "ssh pi sh -s: git config --global user.name 'Me Two'", "ssh pi sh -s: # kore: detect",
        ])
        #expect(BoxParity.gitScript(name: nil, email: "me'2@example.com") == "set -e\ngit config --global user.email 'me'\\''2@example.com'\n")
    }

    @Test func anUnreachableBoxSaysSoWithItsFix() async throws {
        let fake = try FakeSSH(status: 255, said: "me@box: Permission denied (publickey,password).")
        defer { fake.finish() }
        let defaults = try #require(UserDefaults(suiteName: "boxmachine-\(UUID().uuidString)"))
        let list = BoxList(defaults: defaults, hosts: { [] }, cacheRoot: fake.root, setup: { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary())
        })
        list.add("me@box")
        await list.act(.tryAgain, on: "me@box")
        #expect(list.box("me@box")?.note == .init(line: "me@box needs a key · ssh-copy-id me@box", action: .copy("ssh-copy-id me@box")))
    }

    // MARK: Parity

    @Test func parityListsWhatTheBoxLacksWithASafeFixEach() throws {
        var mac = try machine(.macOS)
        mac.versions = ["claude": "2.1.322", "codex": "codex-cli 0.98.0", "gh": "gh version 2.70.0 (2026-01-01)", "git": "git version 2.39.5", "rsync": "openrsync: protocol version 29"]
        mac.tools["codex"] = "/opt/homebrew/bin/codex"
        mac.tools["gh"] = "/opt/homebrew/bin/gh"
        mac.gitName = "Me"
        mac.gitEmail = "me@example.com"
        mac.facts = {
            var facts = AgentFacts()
            facts.claudeMCP = ["files", "linear", "notion", "slack", "web"]
            facts.claudeSkills = ["review"]
            facts.claudeModel = "opus"
            facts.codexMCP = ["linear"]
            return facts
        }()
        var box = try machine(.linuxSystemd)
        box.tools["claude"] = "/home/me/.local/bin/claude"
        box.versions = ["claude": "2.0.11", "git": "git version 2.39.2", "rsync": "rsync  version 3.4.1  protocol version 32"]
        box.gitName = nil
        box.gitEmail = nil
        box.facts = {
            var facts = AgentFacts()
            facts.claudeMCP = ["files"]
            facts.claudeSkills = ["review"]
            facts.claudeModel = "opus"
            return facts
        }()
        let parity = BoxParity.compare(
            mac: mac, box: box, name: "mybox", macLogins: ["claude": BoxLogin(signedIn: true, who: "a@b.c")], boxLogins: ["claude": BoxLogin(signedIn: false)])
        let lines = parity.differences.map(\.line)
        #expect(lines == [
            "claude 2.0 on mybox, 2.1 here", "codex isn't on mybox", "gh isn't on mybox", "claude isn't signed in on mybox",
            "git on mybox has no name · Me <me@example.com> here",
            "claude MCP not on mybox: linear, notion, slack +1", "codex MCP not on mybox: linear",
        ])
        let fixes = Dictionary(uniqueKeysWithValues: parity.differences.map { ($0.id, $0.fix) })
        #expect(fixes["version.claude"] == .install(.claude))
        #expect(fixes["tool.codex"] == .install(.codex))
        #expect(fixes["login.claude"] == .signIn(.claude))
        #expect(fixes["git.identity"] == .gitIdentity(name: "Me", email: "me@example.com"))
        // Config differences are listed, never copied.
        #expect(fixes["claude.mcp"] == .some(nil))
        // Same git and rsync builds aside, nothing else differs.
        #expect(fixes["version.git"] == nil)
        #expect(fixes["version.rsync"] == nil)
        // The same machine against itself: nothing.
        #expect(BoxParity.compare(mac: mac, box: mac, name: "x").isEmpty)
        #expect(BoxLogin.said(BoxAccounts.Line(said: "Signed in as a@b.c.", signedIn: true)) == BoxLogin(signedIn: true, who: "a@b.c"))
    }
}
