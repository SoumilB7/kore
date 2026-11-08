package dev.kore.phone.ui

import android.text.InputType

/**
 * The message field's keyboard flags: a normal text field, so the keyboard's suggestions,
 * learning and voice typing (Gboard's mic) all work. An incognito flag
 * (`IME_FLAG_NO_PERSONALIZED_LEARNING`) or `TYPE_TEXT_FLAG_NO_SUGGESTIONS` turned the mic off
 * (owner, 0.3.0); `ComposerKeysTest` keeps them out.
 */
object ComposerKeys {
    const val INPUT_TYPE = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
        InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
    /** No IME flags at all: nothing that asks for incognito. */
    const val IME_OPTIONS = 0
}
