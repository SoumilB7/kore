import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import Testing

/// Carries that stop and go on: the checkpoint on disk, rsync cut off halfway and run again from
/// it (only the rest crosses), box to box through the Mac's kept folder, Pause and Cancel, and a
/// move's source kept on any doubt. The bytes go through stand-in ssh programs that run here; one
/// cuts the stream after so many bytes (a dropped link), one counts what crosses.
@MainActor
@Suite("resumable carries", .serialized)
struct CarryResumeTests {
    struct Box {
        let rig: BoxRig
        let connection: HostConnection
        var work: String { rig.folder.path }
        @MainActor func carry(_ ssh: SyncBox) -> CarryBox { CarryBox(alias: connection.alias, files: connection, ssh: ssh) }
    }

    func box(_ alias: String) async throws -> Box {
        let rig = try BoxRig()
        let connection = rig.connection()
        connection.retain()
        #expect(await until(5) { connection.isOnline })
        return Box(rig: rig, connection: connection)
    }

    func finish(_ boxes: Box...) {
        for box in boxes {
            box.connection.release()
            box.rig.finish()
        }
    }

    func scratch() throws -> String {
        let path = "/tmp/kcr-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A folder with 6 MB that doesn't compress and two small files.
    func tree(_ parent: String, _ name: String = "proj") throws -> String {
        let root = parent + "/" + name
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        var random = SystemRandomNumberGenerator()
        let big = Data((0..<6_000_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        try big.write(to: URL(fileURLWithPath: root + "/big.bin"))
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("deep\n".utf8).write(to: URL(fileURLWithPath: root + "/sub/b.md"))
        return root
    }

    /// Bytes each counting relay passed, one line per run.
    func sent(_ log: String) -> Int {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int($0) }.reduce(0, +)
    }

    func names(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }

    // MARK: The checkpoint

    @Test func theCheckpointRoundTripsOnDisk() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let journals = CarryJournals(directory: URL(fileURLWithPath: folder + "/transfers"))
        var journal = CarryJournal(
            items: [CarryItem(source: .mac("/Users/me/NCDEX")), CarryItem(source: .box(alias: "two", path: "/srv/a.md"), name: "a 2.md", replace: true)],
            into: .box(alias: "mybox", path: "/home/me/work"), move: true)
        journal.items[0].count = CarryCount(files: 115_013, bytes: 2_123_694_504, dir: true)
        journal.total = 2_123_694_504
        journal.bytes = 601_100_000
        journal.done = 1
        journal.placed = true
        journal.state = .paused
        journal.landed = [.box(alias: "mybox", path: "/home/me/work/NCDEX")]
        journal.updated = Date(timeIntervalSince1970: 1_800_000_000.25)
        journals.save(journal)
        #expect(journals.load(journal.id) == journal)
        #expect(journals.all() == [journal])
        // Its landings: hidden names in the folder that trees leave out.
        let landing = journal.landing(0)
        #expect(landing.parent == journal.folder && landing.name.hasPrefix(".NCDEX.kore-") && FileCarry.isStaging(landing.name))
        #expect(journal.landing(1).name.hasPrefix(".a 2.md.kore-") && FileCarry.isStaging(journal.landing(1).name))
        // A file that doesn't read is dropped; remove takes the staging folder too.
        try Data("{".utf8).write(to: journals.directory.appendingPathComponent("broken.json"))
        try FileManager.default.createDirectory(at: journals.staging(journal.id), withIntermediateDirectories: true)
        #expect(journals.all().map(\.id) == [journal.id])
        #expect(!FileManager.default.fileExists(atPath: journals.directory.appendingPathComponent("broken.json").path))
        journals.remove(journal.id)
        #expect(journals.all().isEmpty && journals.load(journal.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: journals.staging(journal.id).path))
        // One holder of the folder at a time.
        #expect(journals.claim() && journals.claim())
        // A resumable box copy's landing is fixed by where it goes.
        #expect(LinkFiles.copyLanding("/srv/w/.a.kore-12345678") == LinkFiles.copyLanding("/srv/w/.a.kore-12345678"))
        #expect(LinkFiles.copyLanding("/srv/w/x").hasPrefix("/srv/w/.x.kore-") && FileCarry.isStaging((LinkFiles.copyLanding("/srv/w/x") as NSString).lastPathComponent))
        #expect(LinkFiles.copyLanding("/srv/w/x") != LinkFiles.copyLanding("/srv/w/y"))
    }

    // MARK: Mac to box

    /// The link drops halfway through a 6 MB file: rsync stops, the hidden landing stays with the
    /// file's first part, the checkpoint says running, and a move's source stays. A run from the
    /// checkpoint on disk (as after a relaunch) sends only the rest, and the copy lands whole.
    @Test func aCutOffRsyncGoesOnFromItsCheckpointSendingOnlyTheRest() async throws {
        let b = try await box("one")
        let mac = try scratch()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        let count = try #require(CarryCount.mac(source))
        let journals = CarryJournals(directory: URL(fileURLWithPath: mac + "/transfers"))
        let log = mac + "/sent.log"
        let cut = try relaySSH(b.rig.root, name: "cut", limit: 3_000_000, log: log)
        let first = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true,
            boxes: ["one": b.carry(cut)], journals: journals)
        let stopped = await first.run()
        #expect(stopped.interrupted && !stopped.paused && !stopped.cancelled && stopped.landed.isEmpty)
        #expect(!first.steps.contains("trash proj") && CarryCount.mac(source) == count)
        let checkpoint = try #require(journals.load(first.id))
        #expect(checkpoint.state == .running && checkpoint.done == 0 && checkpoint.items[0].count == count)
        let landing = checkpoint.landing(0)
        let partial = CarryCount.mac(landing.path)?.bytes ?? 0
        #expect(partial > 1_000_000 && partial < count.bytes, "\(partial)")
        #expect(sent(log) <= 3_000_000)

        // "Relaunch": the checkpoint read back, a copy this time, the link whole.
        try FileManager.default.removeItem(atPath: log)
        var again = try #require(journals.load(first.id))
        again.move = false
        let counting = try relaySSH(b.rig.root, name: "count", limit: 0, log: log)
        let second = FileCarry(resuming: again, boxes: ["one": b.carry(counting)], journals: journals)
        var told: [Int64] = []
        second.onProgress = { told.append(second.bytes) }
        let done = await second.run()
        #expect(done.failure == nil && done.landed == [.box(alias: "one", path: b.work + "/proj")])
        #expect(second.steps == ["resume proj", "verify proj"])
        #expect(CarryCount.mac(b.work + "/proj") == count && names(b.work) == ["proj"])
        #expect(FileManager.default.contentsEqual(atPath: source + "/big.bin", andPath: b.work + "/proj/big.bin"))
        // Only the rest crossed: well under the whole.
        #expect(sent(log) > 0 && sent(log) < Int(count.bytes) * 7 / 10, "\(sent(log)) of \(count.bytes)")
        // The bar went on from where the checkpoint left it, never back.
        #expect(told.first.map { $0 >= checkpoint.bytes } ?? false)
        #expect(journals.load(first.id) == nil && journals.all().isEmpty)
        #expect(CarryCount.mac(source) == count)
    }

    /// Pause keeps what landed and says paused on disk; Resume goes on; Cancel and remove takes
    /// the partial copy and the checkpoint away, the source untouched.
    @Test func pauseKeepsTheLandingAndCancelRemovesIt() async throws {
        let b = try await box("one")
        let mac = try scratch()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        let journals = CarryJournals(directory: URL(fileURLWithPath: mac + "/transfers"))
        let cut = try relaySSH(b.rig.root, name: "cut", limit: 3_000_000, log: "")
        let first = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true,
            boxes: ["one": b.carry(cut)], journals: journals)
        #expect(await first.run().interrupted)
        let landing = first.journal.landing(0).path
        #expect(FileManager.default.fileExists(atPath: landing))

        // Going again over a slow link, paused: kept, and paused on disk.
        let slow = FileCarry(resuming: try #require(journals.load(first.id)), boxes: ["one": b.carry(try fakeSlowSSH(b.rig.root))], journals: journals)
        let running = Task { await slow.run() }
        try await Task.sleep(for: .milliseconds(400))
        slow.pause()
        let paused = await running.value
        #expect(paused.paused && paused.resumable && !paused.cancelled)
        #expect(journals.load(first.id)?.state == .paused && FileManager.default.fileExists(atPath: landing))

        // Cancel and remove: the landing and the checkpoint go; the source stays.
        let gone = FileCarry(resuming: try #require(journals.load(first.id)), boxes: ["one": b.carry(try fakeSSH(b.rig.root))], journals: journals)
        await gone.discard()
        #expect(!FileManager.default.fileExists(atPath: landing) && names(b.work).isEmpty)
        #expect(journals.load(first.id) == nil && CarryCount.mac(source)?.files == 3)

        // Cancelled while it runs: the same.
        let cancelled = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true,
            boxes: ["one": b.carry(cut)], journals: journals)
        #expect(await cancelled.run().interrupted)
        let again = FileCarry(resuming: cancelled.journal, boxes: ["one": b.carry(try fakeSlowSSH(b.rig.root))], journals: journals)
        let going = Task { await again.run() }
        try await Task.sleep(for: .milliseconds(400))
        again.cancel()
        let ended = await going.value
        #expect(ended.cancelled && names(b.work).isEmpty && journals.all().isEmpty)
    }

    /// A copy that never counts the same (something adds a file to the landing behind rsync's
    /// back): rsync goes over it again, then it fails, the landing kept for Retry, its source
    /// never trashed, and hosts.log names what differs.
    @Test func aCopyThatDoesntMatchKeepsItsLandingAndNeverTrashesTheSource() async throws {
        let b = try await box("one")
        let mac = try scratch()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(mac)
        let journals = CarryJournals(directory: URL(fileURLWithPath: mac + "/transfers"))
        let stray = b.rig.root.appendingPathComponent("stray-ssh")
        try Data("""
            #!/bin/sh
            while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
            shift; shift
            /bin/sh -c "$*"
            status=$?
            for d in "\(b.work)"/.proj.kore-*; do [ -d "$d" ] && echo x > "$d/stray"; done
            exit $status
            """.utf8).write(to: stray)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stray.path)
        let carry = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: true,
            boxes: ["one": b.carry(SyncBox.via(stray.path, alias: "local", base: b.rig.root.path))], journals: journals)
        let outcome = await carry.run()
        let failure = try #require(outcome.failure)
        #expect(!outcome.resumable && failure.contains("didn't match: 4 of 3 files"), "\(failure)")
        #expect(carry.steps == ["copy proj", "verify proj", "verify proj", "verify proj"])
        #expect(!carry.steps.contains("trash proj") && CarryCount.mac(source)?.files == 3)
        // Kept, and failed on disk: Retry goes on from it.
        #expect(FileManager.default.fileExists(atPath: carry.journal.landing(0).path))
        #expect(journals.load(carry.id)?.state == .failed)

        // In place before a stop, but no longer what the source is: the source stays.
        var placed = try #require(journals.load(carry.id))
        try FileManager.default.moveItem(atPath: placed.landing(0).path, toPath: b.work + "/proj")
        placed.placed = true
        let check = FileCarry(resuming: placed, boxes: ["one": b.carry(try fakeSSH(b.rig.root))], journals: journals)
        let checked = await check.run()
        #expect(checked.failure?.contains("original stayed") == true && check.steps == ["verify proj"])
        #expect(CarryCount.mac(source)?.files == 3)
    }

    /// Many small files (20,000 over 200 folders, as a project's dependencies are): they all land
    /// and count the same on both sides, with the landing measured every 20 ms meanwhile (a measure
    /// still running when rsync ends never stands for the check, which counts afresh).
    @Test func aTreeOfManyFilesLandsWholeWhileItsLandingIsMeasured() async throws {
        let b = try await box("one")
        let mac = try scratch()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = mac + "/deps"
        for folder in 0..<200 {
            let path = source + "/p\(folder)/lib"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            for file in 0..<100 {
                FileManager.default.createFile(atPath: path + "/f\(file).js", contents: Data(repeating: 97, count: (folder * 7 + file) % 300))
            }
        }
        let count = try #require(CarryCount.mac(source))
        #expect(count.files == 20_000)
        let carry = FileCarry(items: [CarryItem(source: .mac(source))], into: .box(alias: "one", path: b.work), move: false,
            boxes: ["one": b.carry(try fakeSSH(b.rig.root))])
        carry.pollEvery = .milliseconds(20)
        let done = await carry.run()
        #expect(done.failure == nil && carry.steps == ["copy deps", "verify deps"])
        #expect(CarryCount.mac(b.work + "/deps") == count && names(b.work) == ["deps"])
    }

    // MARK: Box to box

    /// Box to box in two legs through a folder kept on this Mac: the second leg cut off halfway,
    /// the first's bytes stay on the Mac, and the next run sends box B only the rest.
    @Test func boxToBoxGoesOnThroughTheMacsKeptFolder() async throws {
        let a = try await box("one"), b = try await box("two")
        let mac = try scratch()
        defer {
            finish(a, b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(a.work)
        let count = try #require(CarryCount.mac(source))
        let journals = CarryJournals(directory: URL(fileURLWithPath: mac + "/transfers"))
        let log = mac + "/sent.log"
        let first = FileCarry(items: [CarryItem(source: .box(alias: "one", path: source))], into: .box(alias: "two", path: b.work), move: true,
            boxes: ["one": a.carry(try fakeSSH(a.rig.root)), "two": b.carry(try relaySSH(b.rig.root, name: "cut", limit: 3_000_000, log: ""))],
            journals: journals)
        let stopped = await first.run()
        #expect(stopped.interrupted)
        // The first leg whole on the Mac, the second's landing partial on box B, the source there.
        let kept = journals.staging(first.id).appendingPathComponent(first.journal.items[0].token).path
        #expect(CarryCount.mac(kept) == count)
        #expect((CarryCount.mac(first.journal.landing(0).path)?.bytes ?? 0) < count.bytes)
        #expect(CarryCount.mac(source) == count)

        let second = FileCarry(resuming: try #require(journals.load(first.id)),
            boxes: ["one": a.carry(try fakeSSH(a.rig.root)), "two": b.carry(try relaySSH(b.rig.root, name: "count", limit: 0, log: log))],
            journals: journals)
        let done = await second.run()
        #expect(done.failure == nil && done.landed == [.box(alias: "two", path: b.work + "/proj")])
        #expect(CarryCount.mac(b.work + "/proj") == count && names(b.work) == ["proj"])
        #expect(sent(log) > 0 && sent(log) < Int(count.bytes) * 7 / 10, "\(sent(log)) of \(count.bytes)")
        // A move: the source in box A's trash only now; the Mac's folder and checkpoint gone.
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(atPath: journals.staging(first.id).path) && journals.all().isEmpty)
    }

    // MARK: On one box

    /// `fs.copy` with `resume` over the link: a stopped copy's landing is kept, and the next
    /// finishes it.
    @Test func aBoxCopyGoesOnFromItsLanding() async throws {
        let b = try await box("one")
        let mac = try scratch()
        defer {
            finish(b)
            try? FileManager.default.removeItem(atPath: mac)
        }
        let source = try tree(b.work)
        let count = try #require(CarryCount.mac(source))
        try FileManager.default.createDirectory(atPath: b.work + "/dest", withIntermediateDirectories: true)
        let journals = CarryJournals(directory: URL(fileURLWithPath: mac + "/transfers"))
        var journal = CarryJournal(items: [CarryItem(source: .box(alias: "one", path: source))], into: .box(alias: "one", path: b.work + "/dest"), move: false)
        // What a stopped run left: the box's landing for this copy, one file in it whole.
        let inner = LinkFiles.copyLanding(journal.landing(0).path)
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source + "/a.txt", toPath: inner + "/a.txt")
        journal.bytes = 6
        journals.save(journal)
        let carry = FileCarry(resuming: journal, boxes: ["one": b.carry(try fakeSSH(b.rig.root))], journals: journals)
        let done = await carry.run()
        #expect(done.failure == nil && CarryCount.mac(b.work + "/dest/proj") == count)
        #expect(names(b.work + "/dest") == ["proj"] && journals.all().isEmpty)
    }
}

/// A stand-in ssh that relays its input to the command through a counter: `limit` > 0 cuts the
/// stream there (a link that drops; it exits 1), `log` gets the bytes passed. It ends when the
/// command does, as ssh does.
@MainActor
func relaySSH(_ root: URL, name: String, limit: Int, log: String) throws -> SyncBox {
    let relay = root.appendingPathComponent("relay.pl")
    try Data(#"""
        use strict; use IO::Select; use POSIX ":sys_wait_h";
        my ($limit, $log, $cmd) = @ARGV;
        my $pid = open(my $child, "|-", "/bin/sh", "-c", $cmd) or die "spawn";
        binmode STDIN; binmode $child; open(STDOUT, ">", "/dev/null");
        my $sel = IO::Select->new(\*STDIN); my ($sent, $status) = (0, undef);
        LOOP: while (1) {
          if (waitpid($pid, WNOHANG) > 0) { $status = $?; last }
          next unless $sel->can_read(0.1);
          my $n = sysread(STDIN, my $buf, 65536);
          if (!defined $n) { next if $!{EAGAIN}; last }
          last if $n == 0;
          if ($limit > 0 && $sent + $n > $limit) { $buf = substr($buf, 0, $limit - $sent); $n = length $buf; }
          my $off = 0;
          while ($off < $n) { my $w = syswrite($child, $buf, $n - $off, $off); last LOOP unless defined $w; $off += $w }
          $sent += $n;
          last if $limit > 0 && $sent >= $limit;
        }
        if ($log ne "") { open(my $l, ">>", $log); print $l "$sent\n"; close $l }
        close $child;
        $status = $? unless defined $status;
        exit($limit > 0 ? 1 : $status >> 8);
        """#.utf8).write(to: relay)
    let ssh = root.appendingPathComponent(name + "-ssh")
    try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        exec /usr/bin/perl '\(relay.path)' \(limit) '\(log)' "$*"
        """.utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return SyncBox.via(ssh.path, alias: "local", base: root.path)
}
