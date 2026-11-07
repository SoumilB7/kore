import Testing

@testable import KoreUI

@MainActor @Suite struct QuitGuardTests {
    private func counted() -> (QuitGuard, () -> Int) {
        let guardian = QuitGuard()
        var quits = 0
        guardian.terminate = { quits += 1 }
        return (guardian, { quits })
    }

    @Test func oneKeyPressOnlyArms() {
        let (guardian, quits) = counted()
        guardian.press(byKey: true, hasWindow: true)
        #expect(guardian.armed && quits() == 0)
    }

    @Test func theSecondPressOrARepeatQuits() {
        let (guardian, quits) = counted()
        guardian.press(byKey: true, hasWindow: true)
        guardian.press(byKey: true, hasWindow: true)
        #expect(!guardian.armed && quits() == 1)
    }

    @Test func thePointerAndNoWindowQuitAtOnce() {
        let (guardian, quits) = counted()
        guardian.press(byKey: false, hasWindow: true)
        #expect(quits() == 1)
        guardian.press(byKey: true, hasWindow: false)
        #expect(quits() == 2 && !guardian.armed)
    }

    @Test func itDisarmsByItself() async throws {
        let (guardian, quits) = counted()
        guardian.press(byKey: true, hasWindow: true)
        // Its timer waits its turn on a busy main thread: a late disarm still counts.
        try await Task.sleep(for: .seconds(1))
        #expect(guardian.armed)
        for _ in 0..<80 where guardian.armed { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!guardian.armed)
        guardian.press(byKey: true, hasWindow: true)
        #expect(quits() == 0 && guardian.armed)
    }
}
