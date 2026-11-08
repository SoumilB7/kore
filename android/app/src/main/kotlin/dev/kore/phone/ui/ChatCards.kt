package dev.kore.phone.ui

import android.content.Intent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/**
 * A chat row card (spec §5): `l1`, radius 14, a hair edge, 8 apart. The lead is the CLI's logo,
 * or the working spinner in its colour while the chat works (a window's row: a folder). Line 1:
 * the title (Body medium when unread, working or needing you) and the age; line 2 (Callout):
 * the window and the state or last word, warn when it needs you, err when it failed.
 */
fun android.app.Activity.chatCard(): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(dp(14), dp(12), dp(14), dp(12))
    pressFill(Tone.l1, Tone.l2, Radius.row, Tone.hair)
    layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) }
    addView(android.widget.FrameLayout(context).apply {
        addView(android.widget.ImageView(context), android.widget.FrameLayout.LayoutParams(dp(17), dp(17)))
        addView(Spinner(context, Tone.spinClaude).apply { visibility = View.GONE }, android.widget.FrameLayout.LayoutParams(dp(17), dp(17)))
        addView(PromptMark(context).apply { visibility = View.GONE }, android.widget.FrameLayout.LayoutParams(dp(17), dp(17)))
    }, LinearLayout.LayoutParams(dp(17), dp(17)).apply { marginEnd = dp(12) })
    addView(LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(label("").apply { type(Type.Body); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(label("").apply { type(Type.Caption); setTextColor(Tone.faint); setPadding(dp(8), 0, 0, 0) })
        })
        addView(label("").apply { type(Type.Callout); setTextColor(Tone.dim); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(2), 0, 0) })
    }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
}

fun android.app.Activity.bindChatCard(v: LinearLayout, row: DeviceList.Row, open: (() -> Unit)? = null) {
    val lead = v.getChildAt(0) as android.widget.FrameLayout
    val logo = lead.getChildAt(0) as android.widget.ImageView
    val spinner = lead.getChildAt(1) as Spinner
    val prompt = lead.getChildAt(2) as PromptMark
    val text = v.getChildAt(1) as LinearLayout
    val top = text.getChildAt(0) as LinearLayout
    val title = top.getChildAt(0) as TextView
    val age = top.getChildAt(1) as TextView
    val line = text.getChildAt(1) as TextView
    val working = row.cue == DeviceList.Cue.WORKING
    if (row.chatId == null) {
        logo.setImageResource(dev.kore.phone.R.drawable.i_folder)
        logo.imageTintList = android.content.res.ColorStateList.valueOf(Tone.dim)
    } else {
        logo.setImageResource(providerLogo(row.provider))
        logo.imageTintList = null
    }
    logo.visibility = if (working || row.prompt) View.INVISIBLE else View.VISIBLE
    spinner.visibility = if (working && !row.prompt) View.VISIBLE else View.GONE
    prompt.visibility = if (row.prompt) View.VISIBLE else View.GONE
    prompt.needsYou = row.prompt && row.cue == DeviceList.Cue.NEEDS
    spinner.tint = if (row.provider == "codex") Tone.spinCodex else Tone.spinClaude
    title.text = row.title
    val strong = row.unread || working || row.cue == DeviceList.Cue.NEEDS
    title.type(if (strong) Type.BodyMedium else Type.Body)
    title.setTextColor(Tone.text)
    age.text = row.age
    line.text = row.waiting?.let { android.text.SpannableStringBuilder(waitingPrefix(it)).append(row.line) } ?: row.line
    line.visibility = if (row.line.isEmpty() && row.waiting == null) View.GONE else View.VISIBLE
    line.setTextColor(when (row.cue) {
        DeviceList.Cue.NEEDS -> Tone.warn
        DeviceList.Cue.FAILED -> Tone.err
        else -> Tone.dim
    })
    v.contentDescription = listOf(row.title, row.age, if (row.unread) "unread" else "", if (row.prompt) "background commands running" else if (working) "working" else "", row.waiting?.words ?: "", row.line).filter { it.isNotEmpty() }.joinToString(", ")
    v.setOnClickListener {
        if (open != null) open()
        else if (row.chatId != null) startActivity(Intent(this, ChatActivity::class.java).putExtra("chat", row.chatId))
        else startActivity(Intent(this, WindowActivity::class.java).putExtra("window", row.windowId))
    }
}
