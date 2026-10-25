import Testing

@testable import KoreUI

struct LongContextModelsTests {
    private let listed = [
        ModelOption(id: "opus", name: "Opus 5.5", resolved: "claude-opus-5-5", efforts: ["low", "high"]),
        ModelOption(id: "fable", name: "Fable 5.1", resolved: "claude-fable-5-1", efforts: []),
        ModelOption(id: "sonnet", name: "Sonnet 5.5", resolved: "claude-sonnet-5-5", efforts: []),
    ]

    @Test func opusAndSonnetGetA1MOptionBesideThem() {
        let models = ClaudeBackend.withLongContext(listed, applied: "claude-opus-5-5")
        #expect(models.map(\.id) == ["opus", "opus[1m]", "fable", "sonnet", "sonnet[1m]"])
        let long = models[1]
        #expect(long.name == "Opus 5.5 · 1M" && long.resolved == "claude-opus-5-5[1m]" && long.efforts == ["low", "high"])
        // Its own row in the picker, the version its chip.
        let family = ModelFamily.group(models).first { $0.members.contains { $0.model.id == "opus[1m]" } }
        #expect(family?.name == "Opus · 1M")
        #expect(family?.members.first?.version == "5.5")
    }

    @Test func aChatOnAnotherModels1MGetsItsOptionToo() {
        let models = ClaudeBackend.withLongContext(listed, applied: "claude-fable-5-1[1m]")
        #expect(models.map(\.id).contains("fable[1m]"))
    }

    /// Some CLI catalogs name models by family alone: the version comes from the resolved id.
    @Test func bareFamilyNamesGetTheirVersion() {
        #expect(ClaudeBackend.versioned("Opus", resolved: "claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeBackend.versioned("Fable", resolved: "claude-fable-5-1") == "Fable 5.1")
        #expect(ClaudeBackend.versioned("Sonnet", resolved: "claude-sonnet-5") == "Sonnet 5")
        #expect(ClaudeBackend.versioned("Haiku", resolved: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ClaudeBackend.versioned("Opus", resolved: "claude-opus-5-5[1m]") == "Opus 5.5")
        // Named with a version already, or not the family the id says: as the CLI has it.
        #expect(ClaudeBackend.versioned("Opus 5.5", resolved: "claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeBackend.versioned("Default (recommended)", resolved: "claude-opus-5-5") == "Default (recommended)")
        #expect(ClaudeBackend.versioned("Opus", resolved: "opus") == "Opus")
    }
}
