import Foundation

// Plays a recorded CLI session (a cassette) as `claude` or `codex`, so storylines can run Kore's
// real CLI handling with no model (phase 12, package C). Not written yet.
FileHandle.standardError.write(Data("kore-fake-cli: no cassette player yet\n".utf8))
exit(2)
