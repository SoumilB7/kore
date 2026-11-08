import Foundation
import Testing

@testable import KoreUI

/// File icons by name (look §3): whole names first, then the extension.
@Suite("Files: icons by type")
struct FileIconTests {
    @Test func namesMapToTheirGlyph() {
        let table: [(String, FileGlyph)] = [
            ("foo.test.tsx", .typescript), (".env.local", .env), (".env", .env), ("yarn.lock", .lock), ("Dockerfile", .docker),
            ("Dockerfile.dev", .docker), ("README.md", .markdown), ("Makefile", .make), (".gitignore", .gitignore),
            ("Package.resolved", .lock), ("go.mod", .go), ("main.go", .go), ("app.py", .python), ("lib.rs", .rust),
            ("index.js", .javascript), ("data.json", .json), ("ci.yml", .config), ("Cargo.toml", .config),
            ("schema.sql", .sql), ("run.sh", .shell), ("site.css", .css), ("index.html", .html), ("logo.PNG", .image),
            ("spec.pdf", .pdf), ("App.swift", .swift), ("Main.java", .java), ("App.kt", .kotlin), ("x.c", .c),
            ("x.cpp", .cpp), ("x.h", .header), ("notes", .file), (".hidden", .file),
        ]
        for (name, glyph) in table { #expect(FileGlyph.of(name) == glyph, "\(name)") }
    }

    @Test func symbolsAndMonogramsAsSpecified() {
        #expect(FileGlyph.json.symbol == "curlybraces")
        #expect(FileGlyph.env.symbol == "key")
        #expect(FileGlyph.docker.symbol == "cube")
        #expect(FileGlyph.markdown.symbol == "text.alignleft")
        #expect(FileGlyph.config.symbol == "slider.horizontal.3")
        let monograms: [FileGlyph: String] = [
            .typescript: "TS", .javascript: "JS", .python: "PY", .go: "GO", .rust: "RS", .java: "JV", .kotlin: "KT", .c: "C",
            .cpp: "C+", .header: "H",
        ]
        for (glyph, letters) in monograms {
            #expect(glyph.monogram == letters)
            #expect(glyph.symbol == nil)
        }
        // Each glyph draws one or the other.
        #expect(FileGlyph.swift.monogram == nil && FileGlyph.swift.symbol == "swift")
    }

    @Test @MainActor func tintsAreOffByDefault() {
        #expect(Theme.FileType.tint(.typescript) == nil)
    }

    @Test func tenThousandLookupsStayWithinBudget() {
        let names = ["foo.test.tsx", ".env.local", "yarn.lock", "Dockerfile", "README.md", "main.go", "notes", "a.swift"]
        var hits = 0
        // The work itself, as this thread's CPU time: a busy Mac (a gate's parallel run) stretches
        // the clock, not this.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for i in 0..<10_000 where FileGlyph.of(names[i % names.count]) != .file { hits += 1 }
        let took = Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
        #expect(hits == 8750)
        // A row's icon is a lookup: 10k measured 3.6–5 ms of CPU alone, 4.5–8 under a gate's load
        // (debug build). A lookup that went linear over the names would be many times that.
        #expect(took < .milliseconds(25), "\(took)")
    }
}
