package dev.kore.phone.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout

/**
 * When background mode goes on: what keeps the phone connected while the app is closed.
 * Each line is a button that opens the one setting it names.
 */
object Onboarding {
    private const val DONE = "onboarded"

    fun showIfNeeded(activity: Activity) {
        val prefs = activity.getSharedPreferences("kore", Activity.MODE_PRIVATE)
        if (prefs.getBoolean(DONE, false)) return
        prefs.edit().putBoolean(DONE, true).apply()
        show(activity)
    }

    fun show(activity: Activity) {
        val root = activity.window.decorView as FrameLayout
        val scrim = FrameLayout(activity).apply { setBackgroundColor(0x99000000.toInt()); isClickable = true }
        val sheet = activity.column(20).apply { background = activity.rounded(K.surface, 16) }
        val close = { root.removeView(scrim) }
        sheet.addView(activity.label("Stay connected", 18f, K.text, bold = true))
        sheet.addView(activity.label("So alerts reach you while Kore is closed.", 14f, K.dim).apply { setPadding(0, activity.dp(4), 0, activity.dp(12)) })
        val needsNotifications = Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (needsNotifications) sheet.addView(step(activity, "Allow notifications") {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        })
        val power = activity.getSystemService(PowerManager::class.java)
        if (!power.isIgnoringBatteryOptimizations(activity.packageName)) sheet.addView(step(activity, "Battery: Unrestricted") {
            runCatching {
                activity.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${activity.packageName}")))
            }.onFailure { appSettings(activity) }
        })
        if (Build.MANUFACTURER.lowercase() in setOf("oneplus", "oppo", "realme")) {
            sheet.addView(step(activity, "Allow background activity") { appSettings(activity) })
            sheet.addView(activity.label("Then open Recent apps and pull down on Kore's card to lock it.", 13f, K.dim).apply {
                setPadding(0, activity.dp(10), 0, 0)
            })
        }
        sheet.addView(activity.label("Done", 15f, K.accent, bold = true).apply {
            gravity = Gravity.END
            minHeight = activity.dp(48)
            setPadding(0, activity.dp(14), 0, 0)
            setOnClickListener { close() }
        })
        scrim.addView(sheet, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            val m = activity.dp(12); setMargins(m, m, m, m + activity.dp(24))
        })
        root.addView(scrim, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    }

    private fun appSettings(activity: Activity) = runCatching {
        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
    }

    private fun step(activity: Activity, text: String, onClick: () -> Unit): View = activity.label("$text  ›", 15f, K.text).apply {
        gravity = Gravity.CENTER_VERTICAL
        minHeight = activity.dp(48)
        setPadding(activity.dp(14), 0, activity.dp(14), 0)
        background = activity.rounded(K.bg)
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) }
    }
}
