import Foundation
import Testing

@testable import KoreNet

/// What a pipe may run on a box (phase 18 §1 "Bulk"): rsync's `--server` in the forms both
/// clients send (spike 0f), every refusal the plan names, and words a shell would expand.
@Suite("Pipe argv")
struct PipeArgvTests {
    /// As openrsync sends them (spike 0c's argv.log), paths quoted as `SyncBox.spec` quotes them.
    @Test(arguments: [
        ["rsync", "--server", "-g", "-l", "-o", "-p", "-D", "-r", "-t", "--dirs", ".", "'/home/u/small/'"],
        ["rsync", "--server", "--sender", "-g", "-l", "-o", "-p", "-D", "-r", "-t", "--dirs", ".", "/home/u/r/"],
        ["rsync", "--server", "--sender", "-g", "-l", "-o", "-p", "-D", "-t", "--relative", "--dirs", "--files-from=-", "--from0", ".", "/home/u/r/"],
        ["rsync", "--server", "--delete-before", "-c", "-l", "--partial", "-p", "-r", "-t", "-z", "--dirs", ".", "/home/u/small/"],
        // rsync 3: one cluster, its capability letters after `e.` (an `s` there is not -s).
        ["rsync", "--server", "-logDtpre.iLsfxCIvu", "--timeout=60", "--partial", ".", "/home/u/My\\ Code/"],
        ["rsync", "--server", "--sender", "-logDtprze.iLsfxCIvu", ".", "'/home/u/it'\\''s/'"],
    ])
    func takesBothClientsForms(_ words: [String]) throws {
        let argv = try PipeArgv.parse(words)
        #expect(argv.paths.allSatisfy { $0.hasPrefix("/") && !$0.hasPrefix("/'") && !$0.contains("\\") })
        #expect(argv.sender == words.contains("--sender"))
    }

    @Test func unquotesAsTheShellWould() throws {
        #expect(try PipeArgv.parse(["rsync", "--server", "-r", ".", "'/home/u/a b/'"]).paths == ["/home/u/a b/"])
        #expect(try PipeArgv.parse(["rsync", "--server", "-r", ".", "/home/u/a\\ b"]).paths == ["/home/u/a b"])
        #expect(try PipeArgv.parse(["rsync", "--server", "-r", ".", "\"/home/u/q\\\"\""]).paths == ["/home/u/q\""])
        #expect(try PipeArgv.parse(["rsync", "--server", "-r", ".", "'/home/u/it'\\''s'"]).paths == ["/home/u/it's"])
    }

    /// Each refused, and why.
    @Test(arguments: [
        (["sh", "-c", "id"], PipeArgv.Refusal.notRsync),
        (["rsync", "-r", ".", "/home/u"], .notServer),
        (["rsync", "--server", "-e", "ssh", ".", "/home/u"], .refused("-e")),
        (["rsync", "--server", "--rsync-path=/bin/sh", ".", "/home/u"], .refused("--rsync-path")),
        (["rsync", "--server", "--remove-source-files", ".", "/home/u"], .refused("--remove-source-files")),
        (["rsync", "--server", "--log-file=/tmp/x", ".", "/home/u"], .refused("--log-file")),
        (["rsync", "--server", "--backup-dir=/tmp", ".", "/home/u"], .refused("--backup-dir")),
        (["rsync", "--server", "--link-dest=/etc", ".", "/home/u"], .refused("--link-dest")),
        (["rsync", "--server", "--compare-dest=/etc", ".", "/home/u"], .refused("--compare-dest")),
        (["rsync", "--server", "--temp-dir=/tmp", ".", "/home/u"], .refused("--temp-dir")),
        (["rsync", "--server", "-L", ".", "/home/u"], .refused("-L")),
        (["rsync", "--server", "-rk", ".", "/home/u"], .refused("-k")),
        (["rsync", "--server", "-K", ".", "/home/u"], .refused("-K")),
        (["rsync", "--server", "-logDtpHre.iLsfxCIvu", ".", "/home/u"], .refused("-H")),
        (["rsync", "--server", "-rs", ".", "/home/u"], .refused("-s")),
        (["rsync", "--server", "--files-from=/etc/passwd", ".", "/home/u"], .badValue("--files-from")),
        (["rsync", "--server", "--timeout=forever", ".", "/home/u"], .badValue("--timeout")),
        (["rsync", "--server", "--daemon", ".", "/home/u"], .refused("--daemon")),
        (["rsync", "--server", "-R", "--no-implied-dirs", ".", "/home/u"], .unknown("--no-implied-dirs")),
        (["rsync", "--server", "--made-up", ".", "/home/u"], .unknown("--made-up")),
        (["rsync", "--server", "-r", "."], .noPaths),
        (["rsync", "--server", "-r", "/home/u"], .noPaths),
        (["rsync", "--server", "-r", ".", "home/u"], .badPath("home/u")),
        (["rsync", "--server", "-r", ".", "/home/u/../../etc"], .badPath("/home/u/../../etc")),
        (["rsync", "--server", "-r", ".", "/home/$USER"], .shell("/home/$USER")),
        (["rsync", "--server", "-r", ".", "/home/u;id"], .shell("/home/u;id")),
        (["rsync", "--server", "-r", ".", "`id`"], .shell("`id`")),
        (["rsync", "--server", "-r", ".", "~/x"], .shell("~/x")),
        (["rsync", "--server", "-r", ".", "'/home/u"], .shell("'/home/u")),
        (["rsync", "--server", "--server", ".", "/home/u"], .refused("--server")),
    ] as [([String], PipeArgv.Refusal)])
    func refuses(_ words: [String], _ why: PipeArgv.Refusal) {
        #expect(throws: why) { try PipeArgv.parse(words) }
    }

    /// The far end's command: the client's options, then the forced ones (rsync takes the last
    /// word), a timeout of its own unless the client gave one, `.`, the resolved paths.
    @Test func theCommandRunsWithTheForcedOptions() throws {
        let argv = try PipeArgv.parse(["rsync", "--server", "--sender", "-r", ".", "/x"])
        #expect(argv.command(rsync: "/usr/bin/rsync", paths: ["/home/u/x"]) == [
            "/usr/bin/rsync", "--server", "--sender", "-r", "--no-specials", "--no-devices", "--timeout=60", ".", "/home/u/x",
        ])
        let timed = try PipeArgv.parse(["rsync", "--server", "--timeout=30", "-r", ".", "/x"])
        #expect(!timed.command().contains("--timeout=60") && timed.command().contains("--timeout=30"))
    }

    @Test func piecesRoundTrip() {
        for piece in [PipeWire.Piece.data(Data([1, 2, 3])), .data(Data()), .eof, .exit(0), .exit(23), .exit(-1)] {
            #expect(PipeWire.decode(PipeWire.encode(piece)) == piece)
        }
        #expect(PipeWire.decode(Data([9])) == nil && PipeWire.decode(Data([1, 0])) == nil && PipeWire.decode(Data()) == nil)
    }
}
