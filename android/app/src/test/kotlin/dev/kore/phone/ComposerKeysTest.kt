package dev.kore.phone

import android.text.InputType
import android.view.inputmethod.EditorInfo
import dev.kore.phone.ui.ComposerKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gboard's speak-to-type stays on in the message field: no incognito flag, no "no suggestions". */
class ComposerKeysTest {
    @Test fun theMessageFieldAllowsVoiceAndLearning() {
        assertEquals(0, ComposerKeys.IME_OPTIONS and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)
        assertEquals(0, ComposerKeys.INPUT_TYPE and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        assertEquals(InputType.TYPE_CLASS_TEXT, ComposerKeys.INPUT_TYPE and InputType.TYPE_MASK_CLASS)
        // Not a password or visible-password variation (those hide the mic too).
        assertEquals(0, ComposerKeys.INPUT_TYPE and InputType.TYPE_MASK_VARIATION)
        assertTrue(ComposerKeys.INPUT_TYPE and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0)
    }

    /** No field in the app's source asks the keyboard for incognito or no suggestions. */
    @Test fun noFieldAnywhereAsksForIncognito() {
        val src = java.io.File(listOf("src/main/kotlin", "app/src/main/kotlin").first { java.io.File(it).exists() })
        val hits = src.walk().filter { it.extension == "kt" }.flatMap { f ->
            f.readLines().filter { "IME_FLAG_NO_PERSONALIZED_LEARNING" in it || "TYPE_TEXT_FLAG_NO_SUGGESTIONS" in it }
                .filter { !it.trimStart().startsWith("*") && !it.trimStart().startsWith("//") }.map { "${f.name}: $it" }
        }.toList()
        assertTrue(hits.joinToString("\n"), hits.isEmpty())
    }
}
