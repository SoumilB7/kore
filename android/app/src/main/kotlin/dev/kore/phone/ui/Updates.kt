package dev.kore.phone.ui

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import dev.kore.link.update.RangedDownload
import dev.kore.link.update.ReleaseError
import dev.kore.link.update.ReleaseManifest
import dev.kore.link.update.UpdateCheck
import dev.kore.link.update.UpdateOffer
import dev.kore.phone.KoreApp
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * App updates from GitHub's latest release (phase 18 §5): `SHA256SUMS` checked against
 * `SHA256SUMS.sig` with Kore's release key compiled in, `kore.apk` downloaded in ranged,
 * resumable pieces and checked against its signed SHA-256, then the same-signer check (the new
 * APK must be signed by the certificate this app was) before Android's installer sees it.
 */
object Updates {
    sealed class Status {
        data object Idle : Status()
        data object Checking : Status()
        data object UpToDate : Status()
        data class Available(val offer: UpdateOffer) : Status()
        data class Downloading(val percent: Int) : Status()
        data object Installing : Status()
        data class Problem(val line: String) : Status()
    }

    val status = MutableStateFlow<Status>(Status.Idle)
    @Volatile private var lastCheck = 0L

    fun installed(context: Context): String = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"

    /** Asks GitHub for the latest release; [quiet] checks at most once a day (when Home opens). */
    fun check(context: Context, quiet: Boolean = false) {
        val now = System.currentTimeMillis()
        if (quiet && now - lastCheck < 24 * 3_600_000L) return
        lastCheck = now
        if (!quiet) status.value = Status.Checking
        status.value = try {
            val assets = UpdateCheck.assets(get(UpdateCheck.LATEST).decodeToString())
            val sums = assets["SHA256SUMS"]?.first ?: throw ReleaseError("the release has no SHA256SUMS")
            val sig = assets["SHA256SUMS.sig"]?.first ?: throw ReleaseError("the release has no SHA256SUMS.sig")
            val manifest = ReleaseManifest.verified(get(sums), get(sig))
            UpdateCheck.offer(assets, manifest, installed(context))?.let { Status.Available(it) } ?: if (quiet) Status.Idle else Status.UpToDate
        } catch (e: Exception) {
            if (quiet) Status.Idle else Status.Problem(if (e is ReleaseError) e.message ?: "Can't check" else "Can't reach GitHub")
        }
    }

    /** Downloads, verifies and installs [offer]; first time, sends the owner to allow Kore to install apps. */
    suspend fun install(app: KoreApp, offer: UpdateOffer) {
        if (!app.packageManager.canRequestPackageInstalls()) {
            status.value = Status.Problem("Allow Kore to install updates, then tap again.")
            app.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        status.value = Status.Downloading(0)
        val dest = File(app.noBackupFilesDir, "update/kore-${offer.version}.apk").apply { parentFile?.mkdirs() }
        val file = try {
            RangedDownload(offer.url, offer.size, offer.sha256, dest).run { got -> status.value = Status.Downloading((got * 100 / maxOf(1, offer.size)).toInt()) }
        } catch (e: Exception) {
            // What's on disk stays: the next tap goes on from there.
            status.value = Status.Problem(if (e is ReleaseError) e.message ?: "The download didn't match." else "The download stopped. Tap to go on.")
            return
        }
        if (!sameSigner(app, file)) {
            file.delete()
            status.value = Status.Problem("That update isn't signed like this app. Not installed.")
            return
        }
        status.value = Status.Installing
        val installer = app.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply { setAppPackageName(app.packageName) }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("kore.apk", 0, file.length()).use { out -> file.inputStream().use { it.copyTo(out) }; session.fsync(out) }
            val done = PendingIntent.getBroadcast(app, id, Intent(app, InstallResult::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(done.intentSender)
        }
        file.delete()
    }

    /** The APK's signing certificates are this app's (v2/v3, the rotation lineage included). */
    private fun sameSigner(context: Context, apk: File): Boolean {
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: return false
        if (archive.packageName != context.packageName) return false
        val theirs = archive.signingInfo ?: return false
        val mine = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo ?: return false
        val now = mine.apkContentsSigners.map { it.toByteArray().contentHashCode() }.toSet()
        val signers = if (theirs.hasMultipleSigners()) theirs.apkContentsSigners else theirs.signingCertificateHistory
        return signers.any { it.toByteArray().contentHashCode() in now }
    }

    /** A small HTTPS GET (the release JSON, SHA256SUMS and its signature). */
    private fun get(url: String): ByteArray {
        require(url.startsWith("https://"))
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 15_000
        c.setRequestProperty("Accept", "application/vnd.github+json")
        try {
            if (c.responseCode != 200) throw java.io.IOException("HTTP ${c.responseCode}")
            return c.inputStream.use { it.readBytes() }.also { require(it.size < 1 shl 20) }
        } finally {
            c.disconnect()
        }
    }
}

/** Android's answer to an install: confirm on screen, or say why it failed. */
class InstallResult : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            PackageInstaller.STATUS_SUCCESS -> Updates.status.value = Updates.Status.Idle
            else -> Updates.status.value = Updates.Status.Problem(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "The update didn't install.")
        }
    }
}
