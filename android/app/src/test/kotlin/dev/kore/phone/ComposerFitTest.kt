package dev.kore.phone

import dev.kore.phone.ui.ComposerFit
import dev.kore.phone.ui.ComposerFit.Step
import org.junit.Assert.assertEquals
import org.junit.Test

/** The composer bar steps down by measuring (spec §5): the first step that fits; Attach, Arsenal and Send never go. */
class ComposerFitTest {
    // Pill "Auto" with its dot: 70; "Opus 5.5 · high": 110; "Opus 5.5": 64.
    private fun step(room: Int) = ComposerFit.step(room, pill = 70, modelFull = 110, modelShort = 64)

    @Test fun eachStepAtItsEdge() {
        assertEquals(Step.Full, step(180))
        assertEquals(Step.ShortModel, step(179))
        assertEquals(Step.ShortModel, step(134))
        assertEquals(Step.NoModel, step(133))
        assertEquals(Step.NoModel, step(70))
        assertEquals(Step.DotOnly, step(69))
        assertEquals(Step.DotOnly, step(-20))
    }

    @Test fun noModelTextKeepsTheFullStep() {
        assertEquals(Step.Full, ComposerFit.step(70, pill = 70, modelFull = 0, modelShort = 0))
    }
}
