import Foundation
import Testing

@testable import KoreCore

/// What every chat's CLI starts with for Kore (`KoreReach`): PATH with `kore` first, the
/// instructions merged with an imported chat's, the note, and TOML strings for codex's overrides.
@Suite("Kore reach")
struct KoreReachTests {
    @Test func theFolderGoesFirstOnPathOnce() {
        let env = KoreReach.environment(["PATH": "/usr/bin:/k:/bin", "A": "1"], ["A": "2", "B": "3"], pathFirst: "/k")
        #expect(env["PATH"] == "/k:/usr/bin:/bin")
        #expect(env["A"] == "2" && env["B"] == "3")
        #expect(KoreReach.environment(["PATH": "/usr/bin"], [:], pathFirst: nil)["PATH"] == "/usr/bin")
    }

    @Test func instructionsFollowAnImportedChats() {
        #expect(KoreReach.instructions(with: nil) == KoreReach.instructions)
        #expect(KoreReach.instructions(with: "Mine.") == "Mine.\n\n" + KoreReach.instructions)
        #expect(KoreReach.instructions.contains("kore_new_chat"))
    }

    @Test func theNoteNamesTheTierAndIsKnownAsKores() {
        let on = KoreReach.note(tier: "Act unlimited", chat: "1a2b3c4d")
        let off = KoreReach.note(tier: nil, chat: "1a2b3c4d")
        #expect(on == "Kore note: Arsenal is now Act unlimited for this chat (1a2b3c4d): the kore tools act within that tier.")
        #expect(off.contains("now off") && KoreReach.isNote(on) && KoreReach.isNote(off) && !KoreReach.isNote("hello"))
    }

    @Test func tomlStringsEscapeAsJSONDoes() {
        #expect(KoreReach.tomlString("/a b/Kore.app/kore") == #""/a b/Kore.app/kore""#)
        #expect(KoreReach.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
    }

    /// A Kore started from a chat's shell carries its pass and socket: still the owner's run.
    @Test func theAgentChannelsVariablesArentDevHooks() {
        #expect(!KoreReach.isDevRun(["KORE_AGENT_PASS": "p", "KORE_AGENT_SOCKET": "/s", "PATH": "/bin"]))
        #expect(KoreReach.isDevRun(["KORE_AGENT_PASS": "p", "KORE_OPEN": "/f"]))
        #expect(!KoreReach.isDevRun([:]))
    }

    /// A Kore install.sh started after an install or update carries its build settings: still the
    /// owner's run, so its windows' tabs and groups are saved.
    @Test func theInstallersVariablesArentDevHooks() {
        let installed = [
            "KORE_BUILD_SHA": "6d23295", "KORE_SOURCE_COMMIT": "6d2329533cc085e7967971d45a323009b7c03b6c",
            "KORE_RELEASE_TAG": "v0.3.7", "KORE_SIGN_IDENTITY": "Kore", "PATH": "/bin",
        ]
        #expect(!KoreReach.isDevRun(installed))
        #expect(!KoreReach.isDevRun(installed.merging(["KORE_AGENT_PASS": "p"]) { $1 }))
        #expect(KoreReach.isDevRun(installed.merging(["KORE_OPEN": "/f"]) { $1 }))
    }
}
