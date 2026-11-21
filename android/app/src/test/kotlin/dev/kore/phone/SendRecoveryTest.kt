package dev.kore.phone

import dev.kore.phone.ui.SendRecovery
import dev.kore.phone.ui.SendRecovery.Step
import org.junit.Assert.assertEquals
import org.junit.Test

/** A message that didn't go is never lost: its files go up again once, else it's back in the composer. */
class SendRecoveryTest {
    @Test fun lostUploadsGoUpAgainOnceThenTheMessageIsKept() {
        assertEquals(Step.Done, SendRecovery.step(true, null, hasFiles = true, retried = false))
        assertEquals(Step.Reupload, SendRecovery.step(false, "gone.blob", hasFiles = true, retried = false))
        // Sent again with fresh uploads and lost again: kept, not a loop.
        assertEquals(Step.Restore, SendRecovery.step(false, "gone.blob", hasFiles = true, retried = true))
        assertEquals(Step.Restore, SendRecovery.step(false, "gone.blob", hasFiles = false, retried = false))
    }

    @Test fun everyOtherFailureKeepsTheMessage() {
        for (code in listOf("expired", "busy", "denied.sendCap", "rateLimited", "invalid", null)) {
            assertEquals(code.toString(), Step.Restore, SendRecovery.step(false, code, hasFiles = true, retried = false))
        }
    }

    @Test fun theTextComesBackBeforeAnythingTypedSince() {
        assertEquals("hello", SendRecovery.restored("hello", ""))
        assertEquals("hello", SendRecovery.restored("hello", "  "))
        assertEquals("hello\nand more", SendRecovery.restored("hello", "and more"))
        // Already there (a retry tapped twice): not doubled.
        assertEquals("hello there", SendRecovery.restored("hello", "hello there"))
        // Files only: what's typed stays as it is.
        assertEquals("next", SendRecovery.restored("", "next"))
    }

    @Test fun theLineSaysWhyAndThatTheMessageIsKept() {
        assertEquals("Not sent: the files didn't reach mybox. Your message is kept.", SendRecovery.line("gone.blob", null, "mybox"))
        assertEquals("Not sent: connection lost. Your message is kept.", SendRecovery.line("expired", null, "mybox"))
        assertEquals("Not sent: the files couldn't go to mybox again (over 12 MB). Your message is kept.", SendRecovery.line("upload", "over 12 MB", "mybox"))
        assertEquals("This chat only takes messages on the Mac. Your message is kept.", SendRecovery.line("denied.sendCap", null, "MacBook"))
        assertEquals("Not sent: Chat is closed. Your message is kept.", SendRecovery.line("gone.chat", "Chat is closed.", "MacBook"))
    }
}
