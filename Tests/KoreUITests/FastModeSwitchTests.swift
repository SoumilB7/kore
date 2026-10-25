import Foundation
import Testing

@testable import KoreCore
@testable import KoreUI

/// The model picker's fast mode switch: shown only where the CLI says the account and the model
/// can have it, and on or off as the CLI last said.
@MainActor
@Suite("Fast mode switch")
struct FastModeSwitchTests {
    private let fast = ModelOption(id: "big", name: "Big 2", resolved: "big-2", efforts: [], supportsFastMode: true)
    private let plain = ModelOption(id: "small", name: "Small 2", resolved: "small-2", efforts: [])

    private func controls(on model: String) -> ControlsStore {
        let controls = ControlsStore(provider: .claude, memory: ModeMemory(defaults: nil))
        controls.apply(.controlsLoaded(ChatControls(models: [fast, plain], model: model, commands: [])))
        return controls
    }

    @Test func itShowsOnlyOnASupportedModelAndAReportingCLI() {
        let controls = controls(on: "big")
        #expect(!controls.fastModeShown)
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: true)))
        #expect(controls.fastModeShown && !controls.fastMode)
        controls.modelId = "small"
        #expect(!controls.fastModeShown)
    }

    @Test func startingOnAStandardModelDoesNotHideFastModeAfterSwitching() {
        let controls = controls(on: "small")
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: nil)))
        #expect(!controls.fastModeShown)
        controls.modelId = "big"
        #expect(controls.fastModeShown && controls.fastModeEnabled)
        #expect(!controls.fastMode)
    }

    @Test func aReportThatCantSayKeepsWhatWasKnown() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(FastModeReport(on: true, offered: true)))
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: nil)))
        #expect(controls.fastModeShown && !controls.fastMode)
        // The account lost it (extra usage turned off): visible, disabled and off.
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: false)))
        #expect(controls.fastModeShown && !controls.fastModeEnabled && !controls.fastMode)
        #expect(controls.fastUnavailable == "Unavailable for this account")
    }

    @Test func aModelWithoutItLeavesTheSettingForTheNext() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(FastModeReport(on: true, offered: true)))
        controls.modelId = "small"
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: true)))
        controls.modelId = "big"
        #expect(controls.fastModeShown && controls.fastMode)
    }

    @Test func claudesStatesReadAsTheSwitch() {
        #expect(ClaudeBackend.report(ClaudeFastMode(state: .on)) == FastModeReport(on: true, offered: true))
        #expect(ClaudeBackend.report(ClaudeFastMode(state: .cooldown)) == FastModeReport(on: true, paused: true, offered: true))
        #expect(
            ClaudeBackend.report(ClaudeFastMode(state: .off, blocked: "sdk_opt_in_required")) == FastModeReport(on: false, offered: nil))
        #expect(ClaudeBackend.report(ClaudeFastMode(state: .off, blocked: "free")) == FastModeReport(on: false, offered: false, unavailable: "Requires a paid account"))
    }

    @Test func unknownAvailabilityAllowsExplicitOptInWithoutProbing() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(ClaudeBackend.report(ClaudeFastMode(state: .off, blocked: "sdk_opt_in_required"))))
        #expect(controls.fastModeShown && controls.fastModeEnabled && !controls.fastMode)
        #expect(controls.fastUnavailable == nil)
        controls.fastChanging = true
        #expect(!controls.fastModeEnabled)
    }

    @Test func aFreshCLIDoesNotInheritAnotherAccountsBlocker() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(ClaudeBackend.report(ClaudeFastMode(state: .off, blocked: "free"))))
        #expect(!controls.fastModeEnabled)
        controls.apply(.controlsLoaded(ChatControls(models: [fast], model: fast.id, commands: [])))
        #expect(!controls.fastModeShown)
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: nil)))
        #expect(controls.fastModeEnabled && controls.fastUnavailable == nil)
    }

    @Test func anEnabledButBlockedPreferenceCanAlwaysBeTurnedOff() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(ClaudeBackend.report(ClaudeFastMode(state: .on, blocked: "network_error"))))
        #expect(controls.fastMode && controls.fastModeEnabled)
        #expect(controls.fastUnavailable == "Unavailable while the connection is interrupted")
    }

    @Test func refusalExplainsWhyAndAFreshReportRestoresTheSwitch() {
        let controls = controls(on: "big")
        controls.apply(.fastModeChanged(ClaudeBackend.report(ClaudeFastMode(state: .off, blocked: "extra_usage_disabled"))))
        #expect(controls.fastModeShown && !controls.fastModeEnabled)
        #expect(controls.fastUnavailable == "Requires usage credits")
        controls.apply(.fastModeChanged(FastModeReport(on: false, offered: true)))
        #expect(controls.fastModeEnabled && controls.fastUnavailable == nil)
    }
}
