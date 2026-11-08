import Foundation
import HostClient
import Testing

/// A carry's bytes as they move: rsync's progress lines read, and a tar stream counted as it
/// passes through Kore.
struct CarryProgressTests {
    @Test func rsyncsProgressLinesAddUpFileByFile() {
        var progress = RsyncProgress()
        // openrsync: a name, the line redrawn after \r while it goes, then its end.
        progress.feed(Data("./\nbig.bin\n     1048576   5%   10.00MB/s    0:00:19\r".utf8))
        #expect(progress.bytes == 1_048_576)
        progress.feed(Data("    10485760  50%   10.00MB/s    0:00:01\r    20000000 100%  185.47MB/s    0:00:00 (xfer#1, to-check=1/3)\n".utf8))
        #expect(progress.bytes == 20_000_000)
        // rsync 3: commas and "xfr#"; a line split across reads.
        progress.feed(Data("a.txt\n      1,2".utf8))
        #expect(progress.bytes == 20_000_000)
        progress.feed(Data("34 100%    1.00kB/s    0:00:00 (xfr#2, to-chk=0/3)\r\n".utf8))
        #expect(progress.bytes == 20_001_234)
        // Anything else is no progress.
        progress.feed(Data("sent 20001400 bytes  received 64 bytes\ntotal size is 20001234  speedup is 1.00\n".utf8))
        #expect(progress.bytes == 20_001_234)
    }

    @Test func aPipeBetweenTwoStagesIsCountedAsItPasses() async {
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var bytes = 0
            var text = ""
        }
        let count = Count()
        let spawn = Spawn()
        let failed = await spawn.run(
            [["/bin/sh", "-c", "head -c 3000000 /dev/zero"], ["/bin/sh", "-c", "wc -c"]],
            passed: { n in count.lock.withLock { count.bytes += n } })
        #expect(failed == nil && count.bytes == 3_000_000)
        // The last stage's output, as it comes.
        let said = await Spawn().run([["/bin/sh", "-c", "printf 'one\\ntwo\\n'"]], output: { data in count.lock.withLock { count.text += String(decoding: data, as: UTF8.self) } })
        #expect(said == nil && count.text == "one\ntwo\n")
        // A failing stage says why.
        #expect(await Spawn().run([["/bin/sh", "-c", "echo nope >&2; exit 3"]]) == "nope")
    }
}
