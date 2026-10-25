import Foundation
import Testing

@testable import KoreUI

/// A compaction in the middle of a turn (Codex compacts when its window fills, mid-turn): the
/// transcript keeps every row id unique, or SwiftUI's lists draw nothing at all.
@MainActor
struct MidTurnCompactionTests {
    private func turn(_ store: TranscriptStore, _ n: Int, compactions: Int) {
        let id = "t\(n)"
        store.apply(.userMessage(text: "msg \(n)", attachments: []))
        store.apply(.turnStarted(id, origin: .user, at: .now))
        for part in 0...compactions {
            for call in 0..<3 {
                let tool = ToolCall(id: "\(id)-\(part)-\(call)", name: "Run", detail: "ls \(call)")
                store.apply(.toolStarted(tool))
                store.apply(.toolFinished(id: tool.id, output: "ok", isError: false))
            }
            store.apply(.text("\(id)-say-\(part)", .answer, "step \(part)"))
            if part < compactions {
                store.apply(.compactionStarted(auto: true))
                store.apply(.compacted(at: .now, auto: true))
            }
        }
        store.apply(.finalAnswer("\(id)-final"))
        store.apply(.text("\(id)-final", .answer, "done"))
        store.apply(.turnFinished(id, .completed, duration: .seconds(5)))
    }

    @Test(arguments: [1, 2, 3])
    func rowIdsStayUnique(compactions: Int) {
        let store = TranscriptStore()
        turn(store, 1, compactions: 0)
        turn(store, 2, compactions: compactions)
        store.drawNow()
        let sections = store.sections
        #expect(Set(sections.map(\.id)).count == sections.count, "section ids")
        for section in sections {
            let ids = section.items.map(\.id)
            let dupes = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            #expect(dupes.isEmpty, "\(section.id): \(dupes)")
        }
        let all = sections.flatMap(\.items).map(\.id)
        #expect(Set(all).count == all.count, "ids across sections")
    }
}
