package dev.kore.phone.ui

/**
 * A message that didn't go (any refusal, the connection lost): its text and files go back to the
 * composer, never lost. Files the device no longer holds (`gone.blob`: a Mac or box keeps uploads
 * per connection, so a reconnect between the upload and the send drops them) are uploaded again
 * from where they were picked and the message is sent once more; a second failure keeps it too.
 * Pure: the composer asks what to do and what to say.
 */
object SendRecovery {
    enum class Step { Done, Reupload, Restore }

    fun step(ok: Boolean, code: String?, hasFiles: Boolean, retried: Boolean): Step = when {
        ok -> Step.Done
        code == "gone.blob" && hasFiles && !retried -> Step.Reupload
        else -> Step.Restore
    }

    /** The field after a restore: the message's text, before whatever was typed since (once). */
    fun restored(sent: String, typed: String): String = when {
        sent.isBlank() -> typed
        typed.isBlank() -> sent
        typed.startsWith(sent) -> typed
        else -> sent + "\n" + typed
    }

    /** The one line under a restored message: why, then that it's kept. */
    fun line(code: String?, message: String?, device: String): String {
        val why = when (code) {
            "gone.blob" -> "Not sent: the files didn't reach $device."
            "expired" -> "Not sent: connection lost."
            "offline" -> "Not sent: not connected to $device."
            "upload" -> "Not sent: the files couldn't go to $device again${message?.let { " ($it)" } ?: ""}."
            else -> sendWords(code, message)
        }
        return "$why Your message is kept."
    }
}

/** A refused send or answer from a chat, one line (the device's own words where it has them). */
fun sendWords(code: String?, message: String?): String = when (code) {
    "denied.sendCap" -> "This chat only takes messages on the Mac."
    "denied.raiseMode" -> message ?: "That needs your fingerprint first."
    "stale.card", "gone.card" -> "That card changed. Look again."
    "rateLimited" -> "Too fast. Try again in a moment."
    else -> deviceWords(message)?.let { "Not sent: $it" } ?: "Not sent (${code ?: "refused"})."
}

/**
 * A card answer the device refused. Allow on a risky card from a box before 0.3.5 wants the
 * fingerprint the phone no longer gives (`denied.raiseMode`): Allow it there, or update it.
 */
fun answerWords(code: String?, message: String?, device: String, box: Boolean): String = when (code) {
    "denied.raiseMode" -> "Allow this on $device, or update ${if (box) "kore-host" else "Kore"} there."
    else -> sendWords(code, message)
}
