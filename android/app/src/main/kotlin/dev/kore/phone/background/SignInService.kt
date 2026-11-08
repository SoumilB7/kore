package dev.kore.phone.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import dev.kore.phone.R
import dev.kore.phone.ui.JoinActivity

/**
 * Holds the process while the owner signs in to Tailscale in the browser: tsnet keeps the pending
 * node key in memory only, and without a foreground service ColorOS, MIUI and Android 14's
 * cached-app freezer kill or freeze the app behind the browser, so the sign-in finishes for a key
 * that's gone. Started from Join (in front), stopped once the sign-in ends (signed in, cancelled)
 * or after [LIMIT_MS]. A quiet, silent notification; tapping it returns to the Join screen.
 */
class SignInService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val limit = Runnable { stopSelf() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Signing in", NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                setSound(null, null)
            }
        )
        // As the launcher does: the app's task to the front as it was (the browser tab on top, mid sign-in).
        val front = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setClass(this, JoinActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val back = PendingIntent.getActivity(this, 0, front, PendingIntent.FLAG_IMMUTABLE)
        val note = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.kore_mark)
            .setContentTitle("Signing in to Tailscale…")
            .setContentIntent(back)
            .setOngoing(true)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            startForeground(ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (e: Exception) {
            // The sign-in goes on without it (only less sure to survive the browser).
            android.util.Log.w("kore", "sign-in: no foreground service (${e::class.simpleName})")
            stopSelf()
            return START_NOT_STICKY
        }
        main.removeCallbacks(limit)
        main.postDelayed(limit, LIMIT_MS)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacks(limit)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "signin"
        private const val ID = 8
        const val LIMIT_MS = 10 * 60_000L

        /** From the front only (Join pressed): Android 12+ refuses a foreground service started in the background. */
        fun start(context: Context) = runCatching { context.startForegroundService(Intent(context, SignInService::class.java)) }
            .onFailure { android.util.Log.w("kore", "sign-in: service not started (${it::class.simpleName})") }
        fun stop(context: Context) = runCatching { context.stopService(Intent(context, SignInService::class.java)) }
    }
}
