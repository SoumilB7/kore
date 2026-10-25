import AppKit
import Foundation
import KoreUI

/// The model chip's picker (model-picker.html, A): one row per family in the CLI's order, its
/// versions newest first, the current model the accent chip. A chip picks at once and the popup
/// stays; a family's name picks its newest. Effort follows on a slider: a model without the
/// current level takes its nearest level below, the keys and clicks skip the levels it lacks, and
/// a model with none dims it. ↑↓←→ move, Space picks and stays, Return closes; Esc, typing and a
/// second click on the chip close it too. In a narrow tile the chips that don't fit fold into a
/// "…" chip, which unfolds the row.
final class ModelPicker: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    /// One CLI's list, with made-up names: a family of seven versions out of order, a family
    /// whose newer model lacks the middle levels, and a model without efforts.
    struct Cast {
        let models: [ModelOption]
        let effort: String
        let family: String
        let rows: [String]
        /// The newest, its next version, an older one lacking the top levels; the model lacking
        /// the middle level, and the one without efforts.
        let newest: String
        let second: String
        let older: String
        let hollow: String
        let none: String
        /// The oldest version, folded away in a narrow tile; the top level.
        let oldest: String
        let top: String
        let scale: [String]
    }

    static let claude: Cast = {
        let all = ["low", "medium", "high", "xhigh", "max"]
        let three = ["low", "medium", "high"]
        let models = [
            ModelOption(id: "lyra-2", name: "Lyra 2", resolved: "lyra-2", efforts: three),
            ModelOption(id: "lyra-3", name: "Lyra 3", resolved: "lyra-3", efforts: all),
            ModelOption(id: "vega-2", name: "Vega 2", resolved: "vega-2", efforts: ["low", "high"]),
            ModelOption(id: "lyra-2.5", name: "Lyra 2.5", resolved: "lyra-2.5", efforts: Array(all.prefix(4))),
            ModelOption(id: "lyra-1.8", name: "Lyra 1.8", resolved: "lyra-1.8", efforts: three),
            ModelOption(id: "nova", name: "Nova", resolved: "nova", efforts: []),
            ModelOption(id: "lyra-1.5", name: "Lyra 1.5", resolved: "lyra-1.5", efforts: three),
            ModelOption(id: "lyra-1", name: "Lyra 1", resolved: "lyra-1", efforts: three),
            ModelOption(id: "lyra-1.12", name: "Lyra 1.12", resolved: "lyra-1.12", efforts: three),
            ModelOption(id: "vega-1.5", name: "Vega 1.5", resolved: "vega-1.5", efforts: three),
        ]
        return Cast(
            models: models, effort: "xhigh", family: "Lyra",
            rows: ["Lyra: [3] 2.5 2 1.12 1.8 1.5 1", "Vega: 2 1.5", "Nova"],
            newest: "lyra-3", second: "lyra-2.5", older: "lyra-2", hollow: "vega-2", none: "nova", oldest: "lyra-1", top: "max", scale: all)
    }()

    static let codex: Cast = {
        let all = ["minimal", "low", "medium", "high", "xhigh"]
        let four = Array(all.prefix(4))
        let models = [
            ModelOption(id: "atlas-6", name: "Atlas-6", resolved: "atlas-6", efforts: all),
            ModelOption(id: "atlas-6-luna", name: "Atlas-6 Luna", resolved: "atlas-6-luna", efforts: ["low", "high"]),
            ModelOption(id: "atlas-4.1", name: "Atlas-4.1", resolved: "atlas-4.1", efforts: four),
            ModelOption(id: "atlas-5.5", name: "Atlas-5.5", resolved: "atlas-5.5", efforts: all),
            ModelOption(id: "atlas-5", name: "Atlas-5", resolved: "atlas-5", efforts: four),
            ModelOption(id: "atlas-5-mini", name: "Atlas-5 mini", resolved: "atlas-5-mini", efforts: []),
            ModelOption(id: "atlas-4.5", name: "Atlas-4.5", resolved: "atlas-4.5", efforts: four),
            ModelOption(id: "atlas-5.5-luna", name: "Atlas-5.5 Luna", resolved: "atlas-5.5-luna", efforts: ["low", "medium", "high"]),
            ModelOption(id: "atlas-4", name: "Atlas-4", resolved: "atlas-4", efforts: four),
            ModelOption(id: "atlas-3.5", name: "Atlas-3.5", resolved: "atlas-3.5", efforts: four),
        ]
        return Cast(
            models: models, effort: "xhigh", family: "Atlas",
            rows: ["Atlas: [6] 5.5 5 4.5 4.1 4 3.5", "Atlas Luna: 6 5.5", "Atlas mini: 5"],
            newest: "atlas-6", second: "atlas-5.5", older: "atlas-5", hollow: "atlas-6-luna", none: "atlas-5-mini", oldest: "atlas-3.5", top: "xhigh",
            scale: all)
    }()

    static func script(_ cast: Cast) -> CLIScript {
        CLIScript(start: [
            .event(.controlsLoaded(ChatControls(models: cast.models, model: cast.newest, effort: cast.effort, commands: [])))
        ])
    }

    // MARK: Pieces

    static let chip = Locator.id(StoryID.Composer.model)
    static let popup = Locator.id(StoryID.Composer.models)
    static let open: [any Step] = [Press(chip), WaitForElement(popup)]

    static func model(_ what: String, _ id: String, effort: String?) -> Expect {
        Expect(what, found: { story in story.app.chat.map { "\($0.storyModel ?? "none") · \($0.storyEffort ?? "none")" } }) { story in
            story.app.chat?.storyModel == id && story.app.chat?.storyEffort == effort
        }
    }

    static func stops(_ what: String, _ want: [String]) -> Expect {
        Expect(what, found: { $0.app.chat?.storyEffortStops.joined(separator: " ") }) { $0.app.chat?.storyEffortStops == want }
    }

    static func rows(_ what: String, _ want: [String]) -> Expect {
        Expect(what, found: { $0.app.chat?.storyModelRows.joined(separator: " | ") }) { $0.app.chat?.storyModelRows == want }
    }

    static func sent(_ what: String, _ call: Call) -> Expect {
        Expect(what, found: { story in (try? story.scriptedBackend().log).map { "\($0)" } }) { try $0.scriptedBackend().log.contains(call) }
    }

    static let stillOpen = Expect("the picker still open") { $0.app.chat?.isModelPickerOpen == true }

    /// The stops with the thumb on `level`, the keys on the slider, and the levels `offered` has.
    static func scale(_ cast: Cast, thumb: String?, offered: [String], keys: Bool = false) -> [String] {
        (keys ? ["*"] : []) + cast.scale.map { !offered.contains($0) ? "(\($0))" : $0 == thumb ? "[\($0)]" : $0 }
    }

    // MARK: The story

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let cast = codex ? Self.codex : Self.claude
        let models = Dictionary(uniqueKeysWithValues: cast.models.map { ($0.id, $0) })
        let efforts = { (id: String) in models[id]?.efforts ?? [] }
        let chip = { (id: String) in Locator.id(StoryID.Composer.modelChip(id)) }
        let level = { (level: String) in Locator.id(StoryID.Composer.effortLevel(level)) }
        var steps: [any Step] = [
            UseScript(Self.script(cast), for: codex ? "codex" : "claude"), OpenFolder(), StartChat(),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
        // 1 · The chip opens it: the families in the CLI's order, versions newest first.
        steps += Self.open + [
            Self.rows("one row per family, newest first", cast.rows),
            Self.stops("every level, the thumb on the current", Self.scale(cast, thumb: cast.effort, offered: cast.scale)),
            FadesEnd(),
            Snapshot("model-picker"),
        ]
        // 2 · A version picks at once and stays; a model without the level slides to the one below.
        steps += [
            Press(chip(cast.older)),
            Self.model("the older version, its effort the nearest below", cast.older, effort: "high"),
            Self.sent("the CLI told the model", .setModel(cast.older)),
            Self.sent("and the effort", .setEffort("high")),
            Self.stillOpen,
            Self.stops("its missing levels hollow", Self.scale(cast, thumb: "high", offered: efforts(cast.older))),
            // The family's name picks its newest.
            Press(.id(StoryID.Composer.modelFamily(cast.family))),
            Self.model("the newest, by the family's name", cast.newest, effort: "high"),
            Self.stillOpen,
        ]
        // 3 · The keys: ↓ → ↑ to the next version of the first family; Space picks and stays.
        steps += [
            Key(.down), Key(.right), Key(.up),
            Expect("the keys on the second version", found: { $0.app.chat?.storyModelRows.first }) {
                $0.app.chat?.storyModelRows.first?.contains("*") == true
                    && $0.app.chat?.storyModelRows.first?.split(separator: " ").dropFirst(2).first?.hasPrefix("*") == true
            },
            Key(KeyChord(.space)),
            Self.model("Space picked it", cast.second, effort: "high"),
            Self.stillOpen,
            // ↓ past the last family is the slider, where ←→ set the level live.
            Key(.down), Key(.down), Key(.down),
            Self.stops("the keys on the slider", Self.scale(cast, thumb: "high", offered: efforts(cast.second), keys: true)),
            Key(.left),
            Self.model("← a level down", cast.second, effort: "medium"),
            Self.sent("the CLI told", .setEffort("medium")),
        ]
        // 4 · A model lacking the middle levels: hollow stops the thumb skips, by key and by click.
        steps += [
            Press(chip(cast.hollow)),
            Self.model("no medium: the nearest below", cast.hollow, effort: "low"),
            Key(.right),
            Self.model("→ skips the hollow stop", cast.hollow, effort: "high"),
            Self.stops("hollow where it lacks them", Self.scale(cast, thumb: "high", offered: efforts(cast.hollow), keys: true)),
            FadesEnd(),
            Snapshot("model-picker-hollow"),
            Click(level("low")),
            Self.model("a click on a level", cast.hollow, effort: "low"),
            Click(level(cast.top)),
            Self.model("a click on a hollow stop: the nearest offered", cast.hollow, effort: "high"),
        ]
        // 5 · A model without efforts: the track dims, the pill shows the model alone.
        steps += [
            Press(chip(cast.none)),
            Self.stops("every stop hollow", Self.scale(cast, thumb: nil, offered: [], keys: true)),
            Expect("the pill without effort", found: { $0.app.chat?.storyModelPill }) {
                $0.app.chat?.storyModelPill == models[cast.none]?.name
            },
            FadesEnd(),
            Snapshot("model-picker-no-effort"),
            Press(chip(cast.newest)),
            Self.model("back on the newest", cast.newest, effort: "high"),
        ]
        // 6 · Return closes it; so do Esc, typing, and the chip itself.
        steps += [
            Key(.returnKey),
            ExpectElement(Self.popup, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ] + Self.open + [
            Key(.escape),
            ExpectElement(Self.popup, .absent),
            Expect("Esc sent nothing and kept the model") { $0.app.chat?.storyModel == cast.newest },
        ] + Self.open + [
            TypeText("h"),
            ExpectElement(Self.popup, .absent),
            Expect("the key went to the field") { $0.app.chat?.draft == "h" },
            Key(KeyChord(.backspace)),
        ] + Self.open + [
            Click(Self.chip),
            ExpectElement(Self.popup, .absent),
            Expect("the chip's second click closed it") { $0.app.chat?.isModelPickerOpen == false },
        ]
        // 7 · Narrow: the versions that don't fit fold into "…", which unfolds the row.
        steps += [SizeWindow(width: 360)] + Self.open + [
            WaitForElement(.id(StoryID.Composer.modelFold(cast.family))),
            ExpectElement(chip(cast.oldest), .absent),
            FadesEnd(),
            Snapshot("model-picker-narrow"),
            Press(.id(StoryID.Composer.modelFold(cast.family))),
            ExpectElement(.id(StoryID.Composer.modelFold(cast.family)), .absent),
            ExpectElement(chip(cast.oldest)),
            Key(.escape),
            ExpectElement(Self.popup, .absent),
            RestoreWindow(),
        ]
        return steps
    }
}

/// The mode pill's popup: the modes the model offers, as the CLI's own menu lists them (Claude's
/// Auto where the model supports it), the current one ✓, Codex's Plan as a switch under a rule. ↓ and Return pick and close; a click on a mode picks and closes, the Plan
/// switch flips and stays; ⇧Tab cycles without opening it. With it open, a press on the model
/// chip switches to the model picker in one click.
final class ModePicker: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    /// A model that offers Claude's Auto.
    override class var script: CLIScript {
        let model = ModelOption(id: "lyra-3", name: "Lyra 3", resolved: "lyra-3", efforts: ["low", "medium"], supportsAutoMode: true)
        return CLIScript(
            start: [.event(.controlsLoaded(ChatControls(models: [model], model: model.id, effort: "low", commands: [])))],
            turns: [CLIScript.reply("OK")])
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let pill = Locator.id(StoryID.Composer.mode)
        let popup = Locator.id(StoryID.Composer.modes)
        let row = { (id: String) in Locator.id(StoryID.Composer.modeRow(id)) }
        let (first, second) = codex ? ("askForApproval", "approveForMe") : ("default", "acceptEdits")
        let rows = { (what: String, _ want: [String]) in
            Expect(what, found: { $0.app.chat?.storyModeRows.joined(separator: " | ") }) { $0.app.chat?.storyModeRows == want }
        }
        let mode = { (what: String, _ id: String) in
            Expect(what, found: { $0.app.chat?.mode }) { $0.app.chat?.mode == id }
        }
        let open: [any Step] = [Press(pill), WaitForElement(popup)]
        var steps: [any Step] = super.steps() + [WaitForFocus(.id(StoryID.Composer.field))]
        // 1 · The modes, the current one checked.
        steps += open + [
            rows(
                "the modes, Manual checked",
                codex
                    ? ["✓ Ask for approval", "Approve for me", "Full access", "Plan: off"]
                    : ["✓ Manual", "Edit automatically", "Plan", "Auto"]),
            FadesEnd(),
            Snapshot("mode-picker"),
            // 2 · ↓ and Return pick and close.
            Key(.down),
            Expect("the keys on the next mode", found: { $0.app.chat?.storyModeRows.joined(separator: " | ") }) {
                $0.app.chat?.storyModeRows.dropFirst().first?.hasPrefix("*") == true
            },
            Key(.returnKey),
            ExpectElement(popup, .absent),
            mode("Return picked it", second),
            Expect("the CLI told") { try $0.scriptedBackend().log.contains(.setMode(second)) },
        ]
        // 3 · A click on a mode picks it and closes.
        steps += open + [Press(row(first)), ExpectElement(popup, .absent), mode("the click picked it", first)]
        if codex {
            // Plan is a switch: it flips and the popup stays.
            steps += open + [
                Press(row("plan")),
                Expect("plan on") { $0.app.chat?.storyPlanMode == true },
                Expect("the popup still open") { $0.app.chat?.isModePickerOpen == true },
                FadesEnd(),
                Snapshot("mode-picker-plan"),
                Press(row("plan")),
                Expect("plan off") { $0.app.chat?.storyPlanMode == false },
                Key(.escape),
                ExpectElement(popup, .absent),
            ]
        }
        // 4 · ⇧Tab cycles without opening it.
        steps += [
            WaitForFocus(.id(StoryID.Composer.field)),
            Key(KeyChord(.tab, .shift)),
            codex ? Expect("⇧Tab: plan on") { $0.app.chat?.storyPlanMode == true } : mode("⇧Tab: the next mode", second),
            ExpectElement(popup, .absent),
        ]
        // 5 · One click switches to the model picker; the chip's own click closes that.
        steps += open + [
            Press(ModelPicker.chip),
            WaitForElement(ModelPicker.popup),
            Expect("the model picker open, the mode popup gone") {
                $0.app.chat?.isModelPickerOpen == true && $0.app.chat?.isModePickerOpen == false
            },
            Click(ModelPicker.chip),
            ExpectElement(ModelPicker.popup, .absent),
        ]
        // 6 · Claude's Auto, offered by the model: picked, it's checked in its own tint, and the
        // pill reads it.
        if !codex {
            steps += open + [
                Press(row("auto")),
                ExpectElement(popup, .absent),
                mode("Auto picked", "auto"),
            ] + open + [
                rows("Auto checked", ["Manual", "Edit automatically", "Plan", "✓ Auto"]),
                Expect("Auto in the accent's rung, as its pill", found: { $0.app.chat?.storyModeTint("auto") }) {
                    $0.app.chat?.storyModeTint("auto") == "auto" && $0.app.chat?.storyModePill == "Auto"
                },
                FadesEnd(),
                Snapshot("mode-picker-auto"),
                Key(.escape),
                ExpectElement(popup, .absent),
            ]
        }
        return steps
    }
}

/// Fast mode's switch, under the model picker's slider: only where the CLI says the account and
/// the model can have it. A click or Space flips it and the popup stays; a model without it hides
/// the switch, and the next that has it shows it as it was; an account blocker keeps the
/// reason visible and disables the switch.
final class FastModeSwitch: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript {
        let fast = ModelOption(id: "lyra-3", name: "Lyra 3", resolved: "lyra-3", efforts: ["low", "medium"], supportsFastMode: true)
        let plain = ModelOption(id: "nova", name: "Nova", resolved: "nova", efforts: ["low"])
        return CLIScript(
            start: [
                .event(.controlsLoaded(ChatControls(models: [fast, plain], model: fast.id, effort: "low", commands: []))),
                .event(.fastModeChanged(FastModeReport(on: false, offered: nil))),
            ],
            // The account's extra usage was turned off meanwhile: the turn's result says so.
            turns: [[.startTurn] + Beat.answer("OK") + [.event(.fastModeChanged(FastModeReport(on: false, offered: false, unavailable: "Requires usage credits"))), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let row = Locator.id(StoryID.Composer.fastMode)
        let chip = { (id: String) in Locator.id(StoryID.Composer.modelChip(id)) }
        let reads = { (what: String, _ want: String?) in
            Expect(what, found: { $0.app.chat?.storyFastMode ?? "hidden" }) { $0.app.chat?.storyFastMode == want }
        }
        var steps: [any Step] = super.steps() + [WaitForFocus(.id(StoryID.Composer.field))]
        // 1 · Offered: off, under the slider. A click flips it; the popup stays.
        steps += ModelPicker.open + [
            reads("the switch, off", "off"),
            Press(row),
            reads("on", "on"),
            ModelPicker.sent("the CLI told", .setFastMode(true)),
            ModelPicker.stillOpen,
            Snapshot("model-picker-fast"),
        ]
        // 2 · A model without it hides it; back on one with it, it's as it was.
        steps += [
            Press(chip("nova")),
            ExpectElement(row, .absent),
            Press(chip("lyra-3")),
            WaitForElement(row),
            reads("still on", "on"),
        ]
        // 3 · The keys: ↓ past the families and the slider to it, Space flips it and stays.
        steps += [
            Key(.down), Key(.down), Key(.down),
            reads("the keys on it", "*on"),
            Key(KeyChord(.space)),
            reads("Space turned it off", "*off"),
            ModelPicker.sent("the CLI told", .setFastMode(false)),
            ModelPicker.stillOpen,
            Key(.escape),
            ExpectElement(ModelPicker.popup, .absent),
        ]
        // 4 · A blocker stays visible, and clicking it sends no setting.
        steps += [Send("hi"), TurnFinished(1)] + ModelPicker.open + [
            WaitForElement(row),
            reads("unavailable", "unavailable"),
            Press(row),
            Expect("an unavailable switch sends nothing") { try $0.scriptedBackend().log.filter { if case .setFastMode = $0 { true } else { false } }.count == 2 },
            reads("still unavailable", "unavailable"),
            Key(.escape),
            ExpectElement(ModelPicker.popup, .absent),
        ]
        return steps
    }
}

/// Gives the window back the run's size.
struct RestoreWindow: Step {
    var label: String { "Size the window back" }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window else { throw StoryFailure.other("no window") }
        window.setContentSize(story.windowSize)
    }
}

/// Waits out the thumb's slide (`Motion.fade`), so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the slide to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the slide to end") { ContinuousClock.now >= end }
    }
}
