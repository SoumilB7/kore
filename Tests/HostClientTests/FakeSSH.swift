import Foundation
import HostClient

/// ssh and scp stand-ins for one box: a folder for its home, each call logged (`calls`: the
/// options before `--`, then the host and command, and for `sh -s` the script's first line), and
/// answers by machine kind. `status` other than 0 is ssh failing with `said` on stderr.
struct FakeSSH {
    /// What `uname`, os-release and `command -v` say on each kind of box.
    enum Kind {
        case linuxSystemd, linuxNoSystemd, macOS, aarch64, oldMac

        var detection: String {
            switch self {
            case .linuxSystemd:
                return """
                    uname=Linux x86_64
                    uid=1000
                    shell=/bin/bash
                    home=/home/me
                    os.PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
                    os.ID=debian
                    has.systemctl=/usr/bin/systemctl
                    has.loginctl=/usr/bin/loginctl
                    has.rsync=/usr/bin/rsync
                    has.git=/usr/bin/git
                    has.curl=/usr/bin/curl
                    has.bash=/bin/bash
                    has.tar=/usr/bin/tar
                    has.apt-get=/usr/bin/apt-get
                    systemd.user=1
                    free=20000000
                    git.name=Me
                    git.email=me@example.com
                    """
            case .linuxNoSystemd:
                return """
                    uname=Linux x86_64
                    uid=1000
                    os.PRETTY_NAME="Alpine Linux v3.21"
                    os.ID=alpine
                    has.git=/usr/bin/git
                    has.curl=/usr/bin/curl
                    has.tar=/bin/tar
                    has.apk=/sbin/apk
                    free=900000
                    """
            case .macOS:
                return """
                    uname=Darwin arm64
                    uid=501
                    shell=/bin/zsh
                    home=/Users/me
                    macos=15.2
                    has.launchctl=/bin/launchctl
                    has.rsync=/usr/bin/rsync
                    has.git=/usr/bin/git
                    has.curl=/usr/bin/curl
                    has.unzip=/usr/bin/unzip
                    has.brew=/opt/homebrew/bin/brew
                    has.claude=/Users/me/.local/bin/claude
                    free=50000000
                    """
            case .aarch64:
                return """
                    uname=Linux aarch64
                    uid=1000
                    os.PRETTY_NAME="Ubuntu 24.04.1 LTS"
                    os.ID=ubuntu
                    os.ID_LIKE=debian
                    has.systemctl=/usr/bin/systemctl
                    has.rsync=/usr/bin/rsync
                    has.git=/usr/bin/git
                    has.npm=/usr/bin/npm
                    has.codex=/home/me/.npm-global/bin/codex
                    systemd.user=1
                    free=8000000
                    """
            case .oldMac:
                return "uname=Darwin x86_64\nmacos=13.6\nhas.git=/usr/bin/git\n"
            }
        }
    }

    let root: URL
    var box: URL { root.appendingPathComponent("box") }
    var log: URL { root.appendingPathComponent("calls") }
    var shell: BoxShell { BoxShell(ssh: root.appendingPathComponent("ssh").path, scp: root.appendingPathComponent("scp").path) }

    init(_ kind: Kind = .linuxSystemd, status: Int32 = 0, said: String = "", installed: String = "installed") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fakessh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("box"), withIntermediateDirectories: true)
        try Data(kind.detection.utf8).write(to: root.appendingPathComponent("detection"))
        let calls = root.appendingPathComponent("calls").path
        let ssh = """
            #!/bin/sh
            [ "$1 $2 $3 $4 $5" = "-T -o BatchMode=yes -o ConnectTimeout=10" ] || exit 99
            shift 5
            opts=""
            while [ "$1" != "--" ]; do opts="$opts $1"; shift; done
            shift
            host="$1"; cmd="$2"
            line="ssh$opts $host $cmd"
            if [ "$cmd" = "sh -s" ]; then
              script=$(cat)
              first=$(printf '%s\\n' "$script" | grep -v '^set -e$' | grep -v '^mkdir -p' | grep -v '^t=' | grep -v '^trap' | head -n 1)
              line="$line: $first"
            fi
            echo "$line" >> '\(calls)'
            [ \(status) = 0 ] || { echo '\(said)' >&2; exit \(status); }
            case "$cmd" in
              "sh -s") case "$script" in *"# kore: detect"*) cat '\(root.path)/detection' ;; esac ;;
              *".new --version") echo 'kore-host 0.2.3 (link 1.4)' ;;
              *install-service) echo '\(installed)' ;;
            esac
            exit 0
            """
        let scp = """
            #!/bin/sh
            [ "$1 $2 $3" = "-q -o BatchMode=yes" ] || exit 99
            shift 5
            opts=""
            while [ "$1" != "--" ]; do opts="$opts $1"; shift; done
            echo "scp$opts $3" >> '\(calls)'
            cp "$2" '\(root.path)/box/copied'
            """
        for (name, text) in [("ssh", ssh), ("scp", scp)] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func finish() { try? FileManager.default.removeItem(at: root) }

    /// A binary per platform, written as "binary for <platform>".
    func binary() -> @Sendable (BoxBinary.Request) throws -> (url: URL, temporary: Bool) {
        let root = root
        return { request in
            let platform = request.platform
            let file = root.appendingPathComponent("kore-host-\(platform)")
            try Data("binary for \(platform)".utf8).write(to: file)
            return (file, true)
        }
    }
}
