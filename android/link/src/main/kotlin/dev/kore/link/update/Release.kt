package dev.kore.link.update

import com.google.crypto.tink.subtle.Ed25519Verify
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The owner's Ed25519 release key: its raw 32-byte public half, base64, the same string as
 * `Sources/KoreCore/ReleaseKey.swift` (a test keeps them equal). Every release's `SHA256SUMS` is
 * signed with the private half into `SHA256SUMS.sig` (raw 64 bytes).
 */
object KoreReleaseKey {
    // PLACEHOLDER until the owner runs `swift scripts/sign/sign.swift --new-key`: nothing verifies.
    const val BASE64 = "PLACEHOLDER-run-scripts/sign/sign.swift--new-key"

    /** The key, or null while it's still the placeholder. */
    fun key(base64: String = BASE64): ByteArray? = runCatching { Base64.getDecoder().decode(base64) }.getOrNull()?.takeIf { it.size == 32 }
}

class ReleaseError(message: String) : Exception(message)

/**
 * A release's signed `SHA256SUMS`: one header line, `# kore <version> <commit>`, then
 * `<sha256>  <file>` per asset. The signature covers the whole file, header included.
 */
data class ReleaseManifest(val version: String, val commit: String, val files: Map<String, String>) {
    companion object {
        /** [sums] checked against [signature] with [key] (raw 32 bytes), then read. */
        fun verified(sums: ByteArray, signature: ByteArray, key: ByteArray? = KoreReleaseKey.key()): ReleaseManifest {
            key ?: throw ReleaseError("this build has no release key, so nothing can be verified")
            if (signature.size != 64 || runCatching { Ed25519Verify(key).verify(signature, sums) }.isFailure) {
                throw ReleaseError("SHA256SUMS.sig doesn't match SHA256SUMS: not signed by Kore's release key")
            }
            return parse(sums.decodeToString())
        }

        /** Strict: anything but the header and well-formed lines is refused. */
        fun parse(text: String): ReleaseManifest {
            val lines = text.split("\n").let { if (it.lastOrNull() == "") it.dropLast(1) else it }
            val header = lines.firstOrNull()?.split(" ") ?: throw ReleaseError("empty SHA256SUMS")
            if (header.size != 4 || header[0] != "#" || header[1] != "kore" || !isVersion(header[2]) || !isHex(header[3], 40)) {
                throw ReleaseError("SHA256SUMS has no `# kore <version> <commit>` header")
            }
            val files = LinkedHashMap<String, String>()
            for (line in lines.drop(1)) {
                val parts = line.split(" ", limit = 3)
                if (parts.size != 3 || parts[1] != "" || !isHex(parts[0], 64) || !isName(parts[2]) || parts[2] in files) {
                    throw ReleaseError("SHA256SUMS isn't a Kore manifest (${line.take(80)})")
                }
                files[parts[2]] = parts[0]
            }
            return ReleaseManifest(header[2], header[3], files)
        }

        /** "0.10.0" is newer than "0.9.3"; a missing part counts as 0. */
        fun newer(a: String, than: String): Boolean {
            val x = a.split(".").map { it.toIntOrNull() ?: 0 }
            val y = than.split(".").map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(x.size, y.size)) {
                val p = x.getOrElse(i) { 0 }
                val q = y.getOrElse(i) { 0 }
                if (p != q) return p > q
            }
            return false
        }

        private fun isHex(s: String, n: Int) = s.length == n && s.all { it in '0'..'9' || it in 'a'..'f' }
        private fun isVersion(s: String) = s.isNotEmpty() && s.split(".").all { p -> p.isNotEmpty() && p.all { it.isDigit() } }
        private fun isName(s: String) = s.isNotEmpty() && !s.startsWith(".") && s.all { it.isLetterOrDigit() || it in "._-" }
    }
}

/** An update worth downloading: the APK's address, size and SHA-256 as the signed manifest lists it. */
data class UpdateOffer(val version: String, val url: String, val size: Long, val sha256: String)

/**
 * Reads GitHub's latest release (`/repos/SoumilB7/kore/releases/latest`): its `kore.apk`, checked
 * against the signed `SHA256SUMS`. Pure: the app fetches the three small files and passes them in.
 */
object UpdateCheck {
    const val LATEST = "https://api.github.com/repos/SoumilB7/kore/releases/latest"
    const val APK = "kore.apk"

    /** The release's asset URLs by name, and their sizes. */
    fun assets(releaseJson: String): Map<String, Pair<String, Long>> = runCatching {
        val o = Json.parseToJsonElement(releaseJson) as JsonObject
        (o["assets"] as JsonArray).associate { a ->
            val m = a as JsonObject
            (m["name"] as JsonPrimitive).content to ((m["browser_download_url"] as JsonPrimitive).content to ((m["size"] as? JsonPrimitive)?.longOrNull ?: -1L))
        }
    }.getOrDefault(emptyMap())

    /** The APK to download when the signed manifest names a newer version than [installed]; null when up to date. */
    fun offer(assets: Map<String, Pair<String, Long>>, manifest: ReleaseManifest, installed: String): UpdateOffer? {
        if (!ReleaseManifest.newer(manifest.version, installed)) return null
        val sha = manifest.files[APK] ?: throw ReleaseError("SHA256SUMS doesn't list $APK")
        val (url, size) = assets[APK] ?: throw ReleaseError("the release has no $APK")
        if (!url.startsWith("https://")) throw ReleaseError("$APK isn't on https")
        return UpdateOffer(manifest.version, url, size, sha)
    }

    internal fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.contentOrNull
}
