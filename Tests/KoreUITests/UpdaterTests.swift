import Foundation
import Testing

@testable import KoreUI

@Suite("Updates")
struct UpdaterTests {
    @Test func versionsCompareByNumberNotText() {
        #expect(Updater.newer("0.10.0", than: "0.9.3"))
        #expect(Updater.newer("0.3", than: "0.2.9"))
        #expect(!Updater.newer("0.2.3", than: "0.2.3"))
        #expect(!Updater.newer("0.2.3", than: "0.2.3.0"))
        #expect(!Updater.newer("0.2.2", than: "0.2.10"))
    }

    @Test func aReleaseIsItsTagWithoutTheV() {
        #expect(Updater.tag(Data(#"{"tag_name":"v0.3.0","name":"Kore 0.3.0"}"#.utf8)) == "0.3.0")
        #expect(Updater.tag(Data(#"{"tag_name":"0.3.0"}"#.utf8)) == "0.3.0")
        #expect(Updater.tag(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    }
}
