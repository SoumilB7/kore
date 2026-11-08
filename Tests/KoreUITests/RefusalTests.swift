import Foundation
@testable import KoreCore
@testable import src
import Testing

@testable import KoreUI

/// A turn the model's safeguards refuse: with no fallback run, its failure carries the refusal
/// (the notice's two choices); with one, a quiet line names the switch.
@MainActor
@Suite("Refusals")
struct RefusalTests {
    static let folder = URL(fileURLWithPath: "/tmp/kore-tests-refusal")
    static let requesting = #"{"type":"system","subtype":"status","status":"requesting"}"#
    static let noFallback = #"{"type":"system","subtype":"model_refusal_no_fallback","original_model":"vendor-alpha-5-5","request_id":"r1","api_refusal_category":"cyber","content":"","uuid":"u1","session_id":"s1"}"#
    static let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: the model's safeguards flagged this session"}"#

    @Test func aRefusalWithNoFallbackMarksTheFailedTurn() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let events = try ActiveCommandsTests.claude(t, [Self.requesting, Self.noFallback, Self.failed])
        let refused = events.compactMap { if case .refused(_, let r) = $0 { r } else { nil } }
        #expect(refused == [Refusal(category: "cyber", model: "vendor-alpha-5-5")])
        #expect(events.contains { if case .turnFinished(_, .failed, _) = $0 { true } else { false } })
    }

    @Test func aTurnThatWentOnHasNoRefusal() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#
        let events = try ActiveCommandsTests.claude(t, [Self.requesting, Self.noFallback, ok])
        #expect(!events.contains { if case .refused = $0 { true } else { false } })
        // Nor does the next turn's failure, with no refusal of its own.
        let next = try ActiveCommandsTests.claude(t, [Self.requesting, Self.failed])
        #expect(!next.contains { if case .refused = $0 { true } else { false } })
    }

    @Test func theCLIsOwnSwitchIsOneQuietLine() throws {
        let t = ClaudeTranslator(folder: Self.folder, sessionId: "s1")
        let line = #"{"type":"system","subtype":"model_refusal_fallback","direction":"retry","original_model":"vendor-alpha-5-5","fallback_model":"vendor-alpha-4-8","api_refusal_category":"cyber","content":"long text"}"#
        let events = try ActiveCommandsTests.claude(t, [Self.requesting, line])
        #expect(events.contains { if case .notice("Alpha 5.5 flagged this · Alpha 4.8 took it on", false) = $0 { true } else { false } })
    }

    @Test func fallbacksComeFromTheCLIsList() {
        func model(_ id: String) -> ModelOption { ModelOption(id: id, name: id, resolved: id, efforts: []) }
        let list = ["default", "alpha", "vendor-alpha-5", "vendor-alpha-4-8", "vendor-alpha-4-7", "vendor-beta-5",
                    "vendor-gamma-4-5-20251001"].map(model)
        // A cyber flag: the newest of the previous major. Anything else: just below.
        #expect(Refusal(category: "cyber", model: "vendor-alpha-5-5").fallback(in: list)?.id == "vendor-alpha-4-8")
        #expect(Refusal(category: "frontier_llm", model: "vendor-alpha-5-5[1m]").fallback(in: list)?.id == "vendor-alpha-5")
        #expect(Refusal(category: nil, model: "vendor-alpha-5").fallback(in: list)?.id == "vendor-alpha-4-8")
        #expect(Refusal(category: "cyber", model: "vendor-beta-5-5").fallback(in: list) == nil)
        #expect(Refusal(category: "bio", model: "vendor-gamma-4-6").fallback(in: list)?.id == "vendor-gamma-4-5-20251001")
        #expect(Refusal(category: "cyber", model: nil).fallback(in: list) == nil)
        #expect(Refusal.name("vendor-alpha-4-8") == "Alpha 4.8")
        #expect(Refusal.name("vendor-alpha-4-8", in: [ModelOption(id: "vendor-alpha-4-8", name: "Listed", resolved: "", efforts: [])]) == "Listed")
    }

    @Test func theSettingGoesOnTheLaunchFlags() {
        var options = ClaudeSession.Options(cwd: Self.folder, fastMode: true)
        options.switchModelsOnFlag = true
        let args = options.arguments
        let at = args.firstIndex(of: "--settings")
        #expect(at.map { args[$0 + 1] } == #"{"fastMode":true,"switchModelsOnFlag":true}"#)
    }
}
