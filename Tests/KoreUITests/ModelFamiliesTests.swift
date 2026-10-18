import Foundation
import Testing

@testable import KoreUI

/// The model picker's rows (`ModelFamily`), its effort slider (`EffortScale`) and its arrow keys
/// (`ModelPickerGrid`), from made-up model lists.
@MainActor
@Suite("Model families")
struct ModelFamiliesTests {
    private func model(_ name: String, _ efforts: [String] = []) -> ModelOption {
        ModelOption(id: name.lowercased(), name: name, resolved: name.lowercased(), efforts: efforts)
    }

    @Test func aFamilyIsTheNameWithoutItsVersion() {
        #expect(ModelFamily.split("Lyra 4.7") == ("Lyra", "4.7"))
        #expect(ModelFamily.split("Atlas-6 Luna") == ("Atlas Luna", "6"))
        #expect(ModelFamily.split("Atlas-5.1-Pro-Max") == ("Atlas-Pro-Max", "5.1"))
        #expect(ModelFamily.split("Orin 3.5 Swift") == ("Orin Swift", "3.5"))
        #expect(ModelFamily.split("2 Turbo") == ("Turbo", "2"))
        // No number: a family of one. A word with digits in it isn't a version.
        #expect(ModelFamily.split("Nova") == ("Nova", nil))
        #expect(ModelFamily.split("Vega (1M context)") == ("Vega (1M context)", nil))
        #expect(ModelFamily.split("v2x") == ("v2x", nil))
        #expect(ModelFamily.split("7") == ("7", nil))
    }

    @Test func familiesKeepTheListsOrderAndSortVersionsNewestFirst() {
        let families = ModelFamily.group([
            model("Lyra 2"), model("Vega 2"), model("Lyra 3"), model("Nova"), model("Lyra 1.12"), model("Lyra 1.8"),
            model("Vega 1.5"), model("Lyra 2.5"), model("Comet"),
        ])
        #expect(families.map(\.name) == ["Lyra", "Vega", "Nova", "Comet"])
        #expect(families[0].members.compactMap(\.version) == ["3", "2.5", "2", "1.12", "1.8"])
        #expect(families[0].newest.name == "Lyra 3")
        #expect(families[2].versionless && families[3].versionless && !families[0].versionless)
    }

    @Test func codexStyleNamesGroupTheSameWay() {
        let families = ModelFamily.group([
            model("Atlas-6"), model("Atlas-6 Luna"), model("Atlas-5.5"), model("Atlas-5 mini"), model("Atlas-5.5 Luna"),
            model("Atlas-5"),
        ])
        #expect(families.map(\.name) == ["Atlas", "Atlas Luna", "Atlas mini"])
        #expect(families.map { $0.members.compactMap(\.version) } == [["6", "5.5", "5"], ["6", "5.5"], ["5"]])
    }

    @Test func versionsCompareNumberByNumber() {
        #expect(ModelFamily.newer("5.1", "5"))
        #expect(ModelFamily.newer("4.10", "4.9"))
        #expect(!ModelFamily.newer("5", "5.0"))
        #expect(!ModelFamily.newer("2", "10"))
    }

    @Test func chipsThatDontFitFoldIntoTheMoreChip() {
        let widths: [CGFloat] = [30, 30, 30, 30]
        #expect(ModelFamily.fold(widths, more: 20, gap: 4, room: 132) == 4)
        #expect(ModelFamily.fold(widths, more: 20, gap: 4, room: 100) == 2)
        #expect(ModelFamily.fold(widths, more: 20, gap: 4, room: 10) == 0)
        #expect(ModelFamily.fold([], more: 20, gap: 4, room: 0) == 0)
    }

    @Test func theScaleHoldsEveryLevelLowestFirst() {
        let claude = [model("A", ["low", "medium", "high"]), model("B", ["low", "high", "xhigh", "max"])]
        #expect(EffortScale.levels(claude) == ["low", "medium", "high", "xhigh", "max"])
        let codex = [model("C", ["low", "medium", "high", "xhigh"]), model("D", ["minimal", "low"])]
        #expect(EffortScale.levels(codex) == ["minimal", "low", "medium", "high", "xhigh"])
        // Levels Kore doesn't know keep the order the models list them in.
        #expect(EffortScale.levels([model("E", ["calm", "keen"]), model("F", ["keen", "fierce"])]) == ["calm", "keen", "fierce"])
        #expect(EffortScale.levels([model("G")]).isEmpty)
    }

    @Test func aModelWithoutTheLevelTakesTheNearestBelow() {
        let scale = ["low", "medium", "high", "xhigh", "max"]
        #expect(EffortScale.fallback("xhigh", offered: ["low", "medium", "high"], scale: scale) == "high")
        #expect(EffortScale.fallback("medium", offered: ["low", "high"], scale: scale) == "low")
        #expect(EffortScale.fallback("medium", offered: ["medium"], scale: scale) == "medium")
        // Nothing below: its lowest.
        #expect(EffortScale.fallback("low", offered: ["high", "max"], scale: scale) == "high")
        #expect(EffortScale.fallback("high", offered: [], scale: scale) == nil)
        #expect(EffortScale.fallback(nil, offered: ["low"], scale: scale) == nil)
        #expect(EffortScale.fallback("odd", offered: ["medium", "low"], scale: scale) == "low")
    }

    @Test func theThumbSkipsHollowStops() {
        let scale = ["low", "medium", "high", "xhigh", "max"]
        let offered = ["low", "high"]
        #expect(EffortScale.step("low", by: 1, offered: offered, scale: scale) == "high")
        #expect(EffortScale.step("high", by: 1, offered: offered, scale: scale) == "high")
        #expect(EffortScale.step("high", by: -1, offered: offered, scale: scale) == "low")
        #expect(EffortScale.step(nil, by: 1, offered: offered, scale: scale) == "low")
        #expect(EffortScale.step("low", by: 1, offered: [], scale: scale) == nil)
        // A click on a hollow stop: the offered level nearest it, the lower on a tie.
        #expect(EffortScale.nearest(4, offered: offered, scale: scale) == "high")
        #expect(EffortScale.nearest(1, offered: offered, scale: scale) == "low")
        #expect(EffortScale.nearest(2, offered: offered, scale: scale) == "high")
        #expect(EffortScale.name("xhigh") == "Extra high")
    }

    @Test func pickingAModelMovesTheEffortDown() {
        let chat = Chat(provider: .claude, folder: FileManager.default.temporaryDirectory, modeMemory: ModeMemory(defaults: nil))
        let top = model("Lyra 3", ["low", "medium", "high", "xhigh", "max"])
        let older = model("Lyra 2", ["low", "medium", "high"])
        let none = model("Nova")
        chat.controls.apply(.controlsLoaded(ChatControls(models: [top, older, none], model: top.id, effort: "xhigh", commands: [])))
        chat.setModel(older)
        #expect(chat.controls.effort == "high")
        #expect(chat.controls.effortLabel == "High")
        chat.setModel(none)
        #expect(chat.controls.effort == "high")
        #expect(chat.controls.effortLabel == nil)
    }

    @Test func theArrowsWalkTheRowsAndDownToTheSlider() {
        let grid = ModelPickerGrid(rows: [5, 2, 1])
        #expect(grid.move(.chip(row: 0, column: 3), .right) == .chip(row: 0, column: 4))
        #expect(grid.move(.chip(row: 0, column: 4), .right) == .chip(row: 0, column: 4))
        #expect(grid.move(.chip(row: 0, column: 0), .left) == .chip(row: 0, column: 0))
        // Same column, or the row's last chip.
        #expect(grid.move(.chip(row: 0, column: 3), .down) == .chip(row: 1, column: 1))
        #expect(grid.move(.chip(row: 1, column: 1), .up) == .chip(row: 0, column: 1))
        #expect(grid.move(.chip(row: 0, column: 0), .up) == .chip(row: 0, column: 0))
        #expect(grid.move(.chip(row: 2, column: 0), .down) == .effort)
        #expect(grid.move(.effort, .down) == .effort)
        #expect(grid.move(.effort, .up) == .chip(row: 2, column: 0))
        #expect(ModelPickerGrid(rows: []).move(.chip(row: 0, column: 0), .down) == .effort)
    }
}
