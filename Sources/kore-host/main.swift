import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreHost

/// kore-host: Kore's chats on a headless machine, served over the link (`docs/link-1.4-box.md`).
let usage = """
    usage: kore-host run
           kore-host allow <name> [--control watch|act|full]
           kore-host revoke <name>
           kore-host grants
           kore-host attach --as <name>
           kore-host install-service
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = HostPaths()
let grants = GrantStore(paths.grants)
var keep: [Any] = []

switch arguments.first {
case "run":
    signal(SIGPIPE, SIG_IGN)
    HostMemory.smallPages()
    let host = HostDaemon(paths: paths)
    do { try host.start() } catch { fail("\(error)") }
    HostService.notifyReady()
    for (number, action) in [(SIGTERM, "stop"), (SIGINT, "stop"), (SIGHUP, "grants")] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                if action == "grants" {
                    host.grantsChanged()
                } else {
                    host.stop()
                    exit(0)
                }
            }
        }
        source.resume()
        keep.append(source)
    }
    keep.append(host)
    dispatchMain()
case "allow":
    guard arguments.count >= 2 else { fail(usage) }
    var control = GrantControl.act
    if let at = arguments.firstIndex(of: "--control") {
        guard at + 1 < arguments.count, let picked = GrantControl(rawValue: arguments[at + 1]) else { fail("--control is watch, act or full") }
        control = picked
    }
    do {
        let grant = try grants.allow(arguments[1], control: control, socket: paths.socket)
        print("allowed \(grant.name) (\(grant.control.rawValue))")
    } catch { fail("\(error)") }
case "revoke":
    guard arguments.count >= 2 else { fail(usage) }
    guard grants.revoke(arguments[1]) else { fail("no grant named \(arguments[1])") }
    // The daemon closes that grant's connection.
    if let text = try? String(contentsOf: paths.pid, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(pid, SIGHUP)
    }
    print("revoked \(arguments[1])")
case "grants":
    for grant in grants.all() { print("\(grant.name)\t\(grant.control.rawValue)") }
case "attach":
    guard arguments.count >= 3, arguments[1] == "--as" else { fail(usage) }
    guard let grant = grants.load(arguments[2]) else { fail("no grant named \(arguments[2])") }
    signal(SIGPIPE, SIG_IGN)
    MainActor.assumeIsolated {
        do {
            let attach = try Attach(grant: grant) { code in exit(code) }
            attach.start()
            keep.append(attach)
        } catch { fail("\(error)") }
    }
    dispatchMain()
case "install-service":
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    do {
        let file = try HostService.install(executable: executable, home: URL(fileURLWithPath: NSHomeDirectory()))
        print("installed \(file.path)")
    } catch { fail("\(error)") }
default:
    fail(usage)
}
