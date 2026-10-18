import AppKit
import KoreUI

/// Runs user storylines inside the app (phase 12): `kore-storylines` installs it, then starts
/// Kore as usual. Once the app has launched, the runner plays the chosen storylines, writes the
/// report, prints it and exits 0 when every one passed.
///
///     kore-storylines [--tag a,b] [--name A,B] [--provider claude|codex] [--list]
///                     [--out <dir>] [--size WxH] [--replay name|folder|agent:id;…]
///                     [--real-input [--real-keys]]
@MainActor
package enum StorylineHost {
    private static var runner: Runner?
    private static var launched: NSObjectProtocol?

    /// Called by `kore-storylines` before `KoreApp.main()`, with the process's arguments.
    package static func install(arguments: [String]) {
        let options = Options(arguments)
        if options.list {
            for story in Runner.discover() {
                let tags = story.tags.map(\.name).sorted().joined(separator: ",")
                let variants = story.variants.map(\.name).filter { !$0.isEmpty }
                print("\(story.storyName)  [\(tags)]" + (variants.isEmpty ? "" : "  × \(variants.joined(separator: ", "))"))
            }
            exit(0)
        }
        StorylineSeams.events = { chat, event in Runner.current?.record(chat, event) }
        let runner = Runner(selection: options.selection, flags: options.flags, out: options.out)
        self.runner = runner
        launched = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let report = await runner.run()
                print(report.text)
                print("report: \(options.out.path)")
                fflush(stdout)
                exit(report.passed ? 0 : 1)
            }
        }
    }

    struct Options {
        var selection = Runner.Selection()
        var flags = RunFlags()
        var list = false
        var out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kore-storylines/\(Int(Date().timeIntervalSince1970))", isDirectory: true)

        init(_ arguments: [String]) {
            var args = arguments.dropFirst().makeIterator()
            while let arg = args.next() {
                switch arg {
                case "--tag": selection.tags = Set((args.next() ?? "").split(separator: ",").map { Tag(String($0)) })
                case "--name": selection.names = Set((args.next() ?? "").split(separator: ",").map(String.init))
                case "--provider": selection.provider = args.next()
                case "--list": list = true
                case "--out": out = URL(fileURLWithPath: args.next() ?? out.path, isDirectory: true)
                case "--real-input": flags.realInput = true
                case "--real-keys": flags.realKeys = true
                case "--size":
                    let wh = (args.next() ?? "").split(separator: "x").compactMap { Double($0) }
                    if wh.count == 2 { flags.size = CGSize(width: wh[0], height: wh[1]) }
                case "--replay":
                    // verify-landing's KORE_VERIFY_FIXTURES: "name|folder|agent:id;…".
                    for item in (args.next() ?? "").split(separator: ";") {
                        let parts = item.split(separator: "|").map(String.init)
                        if parts.count == 3 { flags.replays[parts[0]] = (URL(fileURLWithPath: parts[1], isDirectory: true), parts[2]) }
                    }
                default:
                    break  // AppKit's own arguments (-NSDocumentRevisionsDebugMode and the like)
                }
            }
            flags.realKeys = flags.realKeys && flags.realInput
        }
    }
}
