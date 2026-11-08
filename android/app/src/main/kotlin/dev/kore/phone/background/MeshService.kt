package dev.kore.phone.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import dev.kore.link.node.NodeMachine
import dev.kore.phone.KoreApp
import dev.kore.phone.R
import dev.kore.phone.ui.HomeActivity
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch

/**
 * Background mode (Settings, off by default): keeps the tailnet and the links while the app is
 * closed, as long as Android shows this service's ongoing notification. Off, the phone's
 * KoreNet runs only while a Kore screen shows (a long-lived tailnet in the background gets
 * Doze-killed and drains the battery on some phones).
 */
class MeshService : Service() {
    private val app get() = application as KoreApp
    private var watch: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Background connection", NotificationManager.IMPORTANCE_LOW).apply {
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setShowBadge(false)
            }
        )
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_OFF) {
            app.mesh.background = false
            return START_NOT_STICKY
        }
        startForeground(ID, ongoing("Kore · connecting"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        watch?.cancel()
        watch = app.scope.launch {
            app.mesh.nodes.flatMapLatest { nodes ->
                if (nodes.isEmpty()) flowOf(emptyList()) else combine(nodes.map { n -> n.state }) { it.toList() }
            }.collect { states ->
                val up = states.count { it == NodeMachine.State.Up }
                val text = if (up == 0) "Kore · reconnecting" else "Kore · $up of ${states.size} connected"
                getSystemService(NotificationManager::class.java).notify(ID, ongoing(text))
            }
        }
        return START_STICKY
    }

    private fun ongoing(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, HomeActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val off = PendingIntent.getService(this, 1, Intent(this, MeshService::class.java).setAction(ACTION_OFF), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.kore_mark)
            .setContentTitle(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setLocalOnly(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .addAction(Notification.Action.Builder(null, "Turn off", off).build())
            .build()
    }

    override fun onDestroy() {
        watch?.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "background"
        private const val ID = 7
        private const val ACTION_OFF = "dev.kore.android.BACKGROUND_OFF"

        fun start(context: Context) = runCatching { context.startForegroundService(Intent(context, MeshService::class.java)) }
        fun stop(context: Context) = runCatching { context.stopService(Intent(context, MeshService::class.java)) }
    }
}
