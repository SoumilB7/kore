package dev.kore.phone.ui

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.kore.link.node.NodeClient
import dev.kore.phone.kore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The bottom of a chat, top to bottom: its open card (a permission, questions or a plan), at most
 * one quiet status line, and the composer: the mode pill, the message field, and Send (Stop while
 * a turn runs). Nothing here overlaps the field: they stack in one column. The Mac checks every
 * command again; this only offers what the chat says it can take.
 */
class ChatActions(private val activity: Activity, private val chatId: String, private val link: () -> NodeClient?) {
    /**
     * The need-you card (spec §5): `l1`, radius 18, a warn edge at 18 %, padding 16, above the
     * composer. Its words scroll when they must; its buttons stay in view under them.
     */
    private val sheet = activity.column()
    private val cardButtons = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val sheetScroll = MaxHeightScroll(activity) { room ->
        val buttons = if (cardButtons.visibility == View.GONE) 0 else cardButtons.measuredHeight.takeIf { it > 0 } ?: activity.dp(60)
        maxOf(activity.dp(64), cardMax(room) - buttons - activity.dp(32))
    }.apply {
        addView(sheet)
        // More above or below fades out at the edge, so a cut card says it scrolls.
        isVerticalFadingEdgeEnabled = true
        setFadingEdgeLength(activity.dp(24))
        // Each time its height changes (the keyboard, a rotation), a cut permission card scrolls
        // so what it would run stays in view; the overline and title give way first.
        addOnLayoutChangeListener { v, _, top, _, bottom, _, oldTop, _, oldBottom ->
            val keep = cardKeep ?: return@addOnLayoutChangeListener
            if (bottom - top == oldBottom - oldTop) return@addOnLayoutChangeListener
            v.post { scrollTo(0, maxOf(0, minOf(keep.bottom - height, keep.top))) }
        }
    }
    /** What a cut card keeps in view: a permission's command. */
    private var cardKeep: View? = null

    private val cardBox = activity.column().apply {
        background = activity.shape(Tone.l1, Radius.card, Tone.warnCard)
        setPadding(activity.dp(16), activity.dp(16), activity.dp(16), activity.dp(16))
        visibility = View.GONE
        addView(sheetScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(cardButtons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    private val status = activity.label("").apply {
        type(Type.Caption)
        setTextColor(Tone.faint)
        setOnClickListener { retry() }
        maxLines = 2
        ellipsize = android.text.TextUtils.TruncateAt.END
        setPadding(activity.dp(6), 0, activity.dp(6), activity.dp(6))
        visibility = View.GONE
    }
    /** The mode pill (spec §5): 30 high, radius 15, `l2`, an 8 dot in the mode's colour, then its name (Label). */
    private val modePill = activity.label("").apply {
        type(Type.Label)
        setTextColor(Tone.text)
        gravity = Gravity.CENTER_VERTICAL
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        contentDescription = "Mode"
        setOnClickListener { chooseMode() }
        pressFill(Tone.l2, Tone.l3, 15)
        // Until the bar measures: the dot alone.
        setPadding(activity.dp(11), 0, activity.dp(11), 0)
        visibility = View.GONE
    }
    /** The chat's model and effort, quiet text beside the mode ("Opus 5.5 · high"); a tap opens the options. */
    private val modelChip = activity.label("").apply {
        type(Type.Label)
        setTextColor(Tone.dim)
        typeface = android.graphics.Typeface.DEFAULT
        gravity = Gravity.CENTER_VERTICAL
        setPadding(activity.dp(6), 0, activity.dp(6), 0)
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        contentDescription = "Model"
        setOnClickListener { chooseMode() }
        pressFill(null, Tone.l2, 15)
        visibility = View.GONE
    }
    /**
     * Arsenal, only while it's on: the Mac's mark (a bolt in a ring) in the tier's colour, 20 dp in
     * a 28×36 dp target. A tap opens the options sheet, whose Arsenal part shows the tier and Stop all.
     */
    private val arsenalMark = android.widget.ImageView(activity).apply {
        setImageResource(dev.kore.phone.R.drawable.ic_arsenal)
        scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
        val pad = activity.dp(4)
        setPadding(pad, activity.dp(8), pad, activity.dp(8))
        setOnClickListener { chooseMode() }
        pressFill(null, Tone.l2, 14)
        visibility = View.GONE
    }
    /** At a plan limit: the draft goes when the limit resets (C7), as the Mac's ring beside Send. */
    private val ring = activity.label("⟳", 15f, K.warn).apply {
        gravity = Gravity.CENTER
        background = activity.shape(android.graphics.Color.TRANSPARENT, 16, Tone.warn)
        contentDescription = "Send at reset"
        visibility = View.GONE
        setOnClickListener { sendAtReset() }
    }
    private val field: EditText = EditText(activity).apply {
        hint = "Message"
        type(Type.Body)
        setHintTextColor(Tone.faint)
        setTextColor(Tone.text)
        background = null
        setPadding(activity.dp(16), activity.dp(11), activity.dp(16), activity.dp(6))
        // A normal text field: the keyboard's suggestions, learning and voice typing all work (an
        // incognito flag turned Gboard's mic off). Nothing typed here is a secret.
        inputType = ComposerKeys.INPUT_TYPE
        imeOptions = ComposerKeys.IME_OPTIONS
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        minLines = 1
        // 1–6 lines, 3 in landscape (spec §5, §7).
        maxLines = if (activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE) 3 else 6
        isVerticalScrollBarEnabled = true
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "Message"
        // A pasted image or file (the clipboard, the keyboard's image insert, a drop) attaches
        // like 📎: a chip, uploaded to the Mac or box. Text pastes as text.
        setOnReceiveContentListener(PASTE_TYPES, android.view.OnReceiveContentListener { _, payload: android.view.ContentInfo ->
            val clip = payload.clip
            val items = (0 until clip.itemCount).map { clip.getItemAt(it) }
            val (files, rest) = items.partition { it.uri != null }
            files.forEach { add(it.uri) }
            when {
                files.isEmpty() -> payload
                rest.isEmpty() -> null
                // Text with the files: the text pastes as text.
                else -> android.view.ContentInfo.Builder(payload)
                    .setClip(android.content.ClipData(clip.description, rest.first()).apply { rest.drop(1).forEach(::addItem) }).build()
            }
        })
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                refreshAction()
                // The device's draft shown here isn't typing: no "/" menu, nothing said back.
                if (showingDraft) return
                showSlash()
                drafts.edited(s?.toString() ?: "", clock())
                scheduleDraft()
            }
        })
        setOnFocusChangeListener { _, has -> ground.focused = has }
    }
    /** Send (spec §5): 36 round; accent with an arrow when there is something to send, `l2` and dim when not, Stop while a turn runs. */
    private val action = ImageView(activity).apply {
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        val pad = activity.dp(9)
        setPadding(pad, pad, pad, pad)
        contentDescription = "Send"
        // While a turn runs (or a compaction): Send with something typed or attached (it queues
        // behind the turn, as on the Mac), Stop with an empty box.
        setOnClickListener { if (running && !hasSomething) stop() else send() }
    }

    private val attach = ImageView(activity).apply {
        setImageResource(dev.kore.phone.R.drawable.i_clip)
        imageTintList = android.content.res.ColorStateList.valueOf(Tone.dim)
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        val pad = activity.dp(8)
        setPadding(pad, pad, pad, pad)
        contentDescription = "Attach"
        pressFill(null, Tone.l2, 18)
        setOnClickListener { if (uploadsOn()) chooseAttachment() else quiet("Uploads arrive with Kore's next update.") }
    }
    /** The attachments, inside the composer above the field: 52 thumbnails, 8 apart. */
    private val chips = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val chipsRow = HorizontalScrollView(activity).apply {
        isHorizontalScrollBarEnabled = false
        clipToPadding = false
        setPadding(activity.dp(10), activity.dp(5), activity.dp(10), 0)
        addView(chips)
        visibility = View.GONE
    }
    private val slashList = activity.column().apply { background = activity.shape(Tone.l1, Radius.menu, Tone.hair2) }
    private val slashScroll = MaxHeightScroll(activity) { minOf(activity.dp(220), maxOf(activity.dp(96), it - composerHeight())) }.apply {
        addView(slashList)
        visibility = View.GONE
    }

    // What the bar's step-down picks from (spec §5): the mode's name and dot, the model's long and short text.
    private var modeText = ""
    private var modelFull: String? = null
    private var modelShort: String? = null

    /** The bar under the field: Attach, the mode pill, the model text, Arsenal, then Send at the end. */
    private inner class ComposerRow : LinearLayout(activity) {
        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(44)
            setPadding(activity.dp(6), activity.dp(2), activity.dp(6), activity.dp(6))
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            if (MeasureSpec.getMode(widthMeasureSpec) != MeasureSpec.UNSPECIFIED) {
                val fixed = (0 until childCount).map { getChildAt(it) }
                    .filter { it.visibility != View.GONE && it !== modePill && it !== modelChip }
                    .sumOf { val lp = it.layoutParams as LayoutParams; maxOf(lp.width, 0) + lp.marginStart + lp.marginEnd }
                fit(MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight - fixed)
            }
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        }
    }

    /** Takes the first step that fits [room] px (spec §5 step-down); Attach, Arsenal and Send never go. */
    private fun fit(room: Int) {
        val gap = activity.dp(6)
        val pill = if (modePill.visibility == View.GONE) 0 else modePill.paint.measureText(modeText).toInt() + activity.dp(9 + 8 + 7 + 12) + gap
        val chrome = modelChip.paddingLeft + modelChip.paddingRight
        val full = modelFull?.let { modelChip.paint.measureText(it).toInt() + chrome } ?: 0
        val short = modelShort?.let { modelChip.paint.measureText(it).toInt() + chrome } ?: 0
        val step = ComposerFit.step(room, pill, full, short)
        val label = if (step == ComposerFit.Step.DotOnly) "" else modeText
        if (modePill.text.toString() != label) {
            modePill.text = label
            if (label.isEmpty()) {
                modePill.compoundDrawablePadding = 0
                modePill.setPadding(activity.dp(11), 0, activity.dp(11), 0)
            } else {
                modePill.compoundDrawablePadding = activity.dp(7)
                modePill.setPadding(activity.dp(9), 0, activity.dp(12), 0)
            }
        }
        val model = when (step) {
            ComposerFit.Step.Full -> modelFull
            ComposerFit.Step.ShortModel -> modelShort
            else -> null
        }
        if (modelChip.text.toString() != (model ?: "")) modelChip.text = model ?: ""
        modelChip.visibility = if (model != null) View.VISIBLE else View.GONE
    }

    private val ground = ComposerGround(activity.resources.displayMetrics.density)
    private val bar = ComposerRow().apply {
        addView(attach, LinearLayout.LayoutParams(activity.dp(36), activity.dp(36)))
        addView(modePill, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, activity.dp(30)).apply { marginStart = activity.dp(6) })
        addView(modelChip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, activity.dp(30)))
        addView(arsenalMark, LinearLayout.LayoutParams(activity.dp(28), activity.dp(36)))
        addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f))
        addView(ring, LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)).apply { marginEnd = activity.dp(8) })
        addView(action, LinearLayout.LayoutParams(activity.dp(36), activity.dp(36)))
    }
    /** The composer (spec §5): `l1`, radius 22, a hair2 edge (accent while typing) and the lift. */
    private val box = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        background = ground
        addView(chipsRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(field, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    val view: View = activity.column().apply {
        setPadding(activity.dp(12), activity.dp(8), activity.dp(12), activity.dp(10))
        // The composer's lift draws above it, over the transcript's end.
        clipChildren = false
        clipToPadding = false
        addView(cardBox, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = activity.dp(10) })
        addView(slashScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = activity.dp(8) })
        addView(status)
        addView(box, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    /** The composer's height as last laid out (before its first layout: a one-line field and the bar). */
    private fun composerHeight(): Int = box.measuredHeight.takeIf { it > 0 } ?: activity.dp(96)

    /**
     * The card takes at most half the space above the composer (spec §5, §7), out of [room]: what
     * the chat's column has below the bar now, so a keyboard shrinks the card, never the composer.
     */
    private fun cardMax(room: Int): Int = maxOf(activity.dp(96), (room - composerHeight()) / 2)

    private var chat: JsonObject? = null
    private var snapshot: JsonObject? = null

    // The draft, kept in step with the device's (typing here said once it rests; theirs shown here).
    private var showingDraft = false
    private val drafts: DraftSync = DraftSync(
        send = { text -> link()?.command(dev.kore.link.node.Control.setDraft(chatId, text)) },
        show = { text ->
            showingDraft = true
            field.setText(text)
            field.setSelection(text.length)
            showingDraft = false
        },
    )
    private val draftTick = Runnable { drafts.tick(clock()); scheduleDraft() }
    private fun clock() = android.os.SystemClock.uptimeMillis()
    private fun scheduleDraft() {
        field.removeCallbacks(draftTick)
        drafts.due?.let { field.postDelayed(draftTick, maxOf(0L, it - clock())) }
    }

    /** Leaving the chat or going to the background: what's typed is said now. */
    fun leave() {
        field.removeCallbacks(draftTick)
        drafts.flush(clock())
    }
    /** Sheets drawn from the chat's state, redrawn as it changes. */
    private val live = ArrayList<Sheet>()
    /** Choices sent and not yet in the Mac's state: model, effort, fast, autoCompact. */
    private val want = HashMap<String, String>()
    private var canSend = false
    private var running = false
    private var note = ""
    private var cardKey: String? = null
    private val pending = HashMap<String, String>()
    /** What a send carried, so one that expired offline can be sent again with a tap. */
    private val sentText = HashMap<String, String>()
    private var retryText: String? = null

    fun render(chat: JsonObject?, snapshot: JsonObject? = this.snapshot) {
        this.chat = chat
        this.snapshot = snapshot
        // What the phone asked for shows at once; the Mac's own value takes over once it matches.
        chat?.obj("controls")?.let { c ->
            if (want["model"] == c.str("modelId")) want.remove("model")
            if (want["effort"] == c.str("effort")) want.remove("effort")
            if (want["fast"] == c.bool("fast").toString()) want.remove("fast")
            if (want["autoCompact"] == (c["autoCompactAt"].int()?.toString() ?: "off")) want.remove("autoCompact")
        }
        chat?.obj("controls")?.let { c -> drafts.remote(c.str("draft"), c["draftRev"].int(), clock()); scheduleDraft() }
        canSend = chat?.obj("can")?.bool("send") ?: false
        running = chat?.bool("running") == true
        // The field is always there and always takes a tap; only Send waits for the chat.
        field.alpha = if (chat == null || canSend) 1f else 0.6f
        val mode = chat?.let { modeLabel(it, it.obj("mode")?.str("id")) }
        // The pill's words are set by the bar's step-down (fit), which may show only its dot.
        modeText = mode ?: ""
        val dot = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setColor(modeColor(chat?.obj("mode")?.get("level").int()))
            setSize(activity.dp(8), activity.dp(8))
        }
        modePill.setCompoundDrawablesRelativeWithIntrinsicBounds(dot, null, null, null)
        modePill.visibility = if (mode != null) View.VISIBLE else View.GONE
        modePill.contentDescription = mode?.let { "Mode: $it" } ?: "Mode"
        val controls = chat?.obj("controls")
        val chip = controls?.let {
            ControlModel.modelChip(ControlModel.models(snapshot, chat.str("provider")), want["model"] ?: it.str("modelId"), chat.str("model"), want["effort"] ?: it.str("effort"))
        }
        if (chip != modelFull) {
            modelFull = chip
            modelShort = chip?.substringBefore(" · ")
            modelChip.text = ""
        }
        // The bar measures again and takes the step that fits (spec §5).
        bar.requestLayout()
        val tier = chat?.str("arsenal")?.takeIf { it != "off" }
        arsenalMark.visibility = if (tier != null) View.VISIBLE else View.GONE
        arsenalMark.imageTintList = android.content.res.ColorStateList.valueOf(arsenalTint(tier))
        arsenalMark.contentDescription = "Arsenal ${dev.kore.link.node.Control.arsenalName(tier)}"
        refreshAction()
        showStatus()
        live.forEach { if (it.isShowing) it.refresh() }
        val card = chat?.objs("cards")?.firstOrNull()
        val key = card?.let { "${it.str("id")}/${it.str("digest")}" }
        if (key != cardKey) {
            cardKey = key
            showCard(card)
        }
    }

    /** `result {id, ok, code?}` for a command sent from here. */
    fun result(r: JsonObject) {
        val id = r.str("id") ?: return
        val kind = pending.remove(id) ?: return
        if (kind in CONTROL) return controlResult(kind, r)
        val text = sentText.remove(id)
        retryText = null
        if (r.bool("ok")) {
            note = if (kind == "send") "✓ Sent" else ""
            showStatus()
            if (note.isNotEmpty()) status.postDelayed({ if (note == "✓ Sent") { note = ""; showStatus() } }, 1500)
            return
        }
        if (r.str("code") == "expired" && text != null) {
            retryText = text
            note = "Not sent: connection lost. Tap to retry."
            showStatus()
            return
        }
        note = when (r.str("code")) {
            "denied.sendCap" -> "This chat only takes messages on the Mac."
            "denied.raiseMode" -> r.str("message") ?: "That needs your fingerprint first."
            // A risky card's Allow without the fingerprint: nothing was sent.
            "cancelled" -> "Allow needs your fingerprint."
            "stale.card", "gone.card" -> "That card changed. Look again."
            "rateLimited" -> "Too fast. Try again in a moment."
            else -> "Not sent (${r.str("code") ?: "refused"})."
        }
        showStatus()
    }

    /** Something to send: typed text, or an attachment. */
    private val hasSomething: Boolean get() = this.field.text.isNotBlank() || attachments.isNotEmpty()

    /** What Send/Stop shows now (0 at rest, 1 ready, 2 Stop): its ground is drawn again only on a change. */
    private var actionLook = -1

    private fun refreshAction() {
        val atLimit = ControlModel.limitReset(chat?.obj("rescue")) != null && chat?.obj("can")?.bool("sendAtReset") == true
        ring.visibility = if (atLimit) View.VISIBLE else View.GONE
        ring.alpha = if (field.text.isNotBlank()) 1f else 0.45f
        // As the full-control mockup: Stop a raised square with a light ■; Send at rest raised with
        // a dim arrow, lit once there is something to send.
        val ready = canSend && hasSomething
        val look = if (running && !hasSomething) 2 else if (ready) 1 else 0
        if (look == actionLook) return
        actionLook = look
        val (icon, ink, fill, pressed) = when (look) {
            2 -> listOf(dev.kore.phone.R.drawable.i_stop, Tone.text, Tone.l2, Tone.l3)
            1 -> listOf(dev.kore.phone.R.drawable.i_up, Tone.onAccent, Tone.accent, Tone.b400)
            else -> listOf(dev.kore.phone.R.drawable.i_up, Tone.dim, Tone.l2, Tone.l3)
        }
        action.setImageResource(icon)
        action.imageTintList = android.content.res.ColorStateList.valueOf(ink)
        action.contentDescription = if (look == 2) "Stop" else "Send"
        action.isEnabled = look != 0
        action.pressFill(fill, pressed, 18)
    }

    /** One line at most: what just happened, else why sending is off. */
    private fun showStatus() {
        val text = when {
            note.isNotEmpty() -> note
            chat != null && !canSend -> "This chat can't take a message from the phone right now."
            else -> ""
        }
        status.text = text
        status.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun quiet(text: String) {
        note = text
        retryText = null
        showStatus()
    }

    /** The status line, tapped after a send expired offline: send that text again. */
    private fun retry() {
        val text = retryText ?: return
        val l = link() ?: return quiet("Not connected")
        val id = l.send(chatId, text)
        pending[id] = "send"
        sentText[id] = text
        retryText = null
        note = if (id in l.queued.value) "⟳ Waiting for the connection, sends when it's back" else "Sending…"
        showStatus()
    }

    private fun send() {
        val text = field.text.toString().trim()
        if ((text.isEmpty() && attachments.isEmpty()) || !canSend) return
        val l = link() ?: return quiet("Not connected")
        if (attachments.any { it.blobId == null && !it.failed }) return quiet("Waiting for the attachments to upload…")
        val blobs = attachments.mapNotNull { it.blobId }
        showingDraft = true
        field.setText("")
        showingDraft = false
        attachments.clear()
        showChips()
        val id = l.send(chatId, text, blobs)
        // Sent: the draft goes everywhere (after the message, so it never goes first).
        drafts.sent(clock())
        scheduleDraft()
        pending[id] = "send"
        sentText[id] = text
        quiet(if (id in l.queued.value) "⟳ Waiting for the connection, sends when it's back" else "Sending…")
    }

    // Attachments: picked with the system's own pickers, uploaded at once, sent with the message.

    private class Attachment(val name: String, val thumb: Bitmap?) {
        var blobId: String? = null
        var failed = false
    }
    private val attachments = ArrayList<Attachment>()
    private var shot: Uri? = null

    /** Uploads only once the Mac side offers them (link 1.1); until then 📎 says so instead. */
    private fun uploadsOn(): Boolean = hasCap("blob") || hasCap("upload")

    /** What the Mac side offers this link (welcome `caps`): "blob" for uploads, "commands" for the "/" list. */
    private fun hasCap(name: String): Boolean {
        val caps = link()?.welcome?.value?.get("caps") as? kotlinx.serialization.json.JsonArray ?: return false
        return caps.any { (it as? kotlinx.serialization.json.JsonPrimitive)?.content == name }
    }

    /** The Attach sheet (spec §6): three tiles, Photos, Camera and File, and the size limit under them. */
    private fun chooseAttachment() {
        lateinit var s: Sheet
        fun tile(icon: Int, title: String, go: () -> Unit) = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(activity.dp(12), activity.dp(16), activity.dp(12), activity.dp(16))
            pressFill(Tone.l2, Tone.l3, Radius.card)
            contentDescription = title
            setOnClickListener { s.dismiss(); go() }
            addView(android.widget.FrameLayout(activity).apply {
                background = activity.shape(Tone.l3, 16)
                addView(ImageView(activity).apply {
                    setImageResource(icon)
                    imageTintList = android.content.res.ColorStateList.valueOf(Tone.b200)
                }, android.widget.FrameLayout.LayoutParams(activity.dp(24), activity.dp(24), Gravity.CENTER))
            }, LinearLayout.LayoutParams(activity.dp(48), activity.dp(48)))
            addView(activity.label(title).apply { type(Type.Label); setTextColor(Tone.text); gravity = Gravity.CENTER },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(10) })
        }
        val tiles = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(activity.dp(4), 0, activity.dp(4), 0)
            val go = listOf(
                tile(dev.kore.phone.R.drawable.i_image, "Photos") { activity.startActivityForResult(Intent(MediaStore.ACTION_PICK_IMAGES), PICK) },
                tile(dev.kore.phone.R.drawable.i_camera, "Camera") {
                    val dir = java.io.File(activity.cacheDir, "shots").apply { mkdirs() }
                    val file = java.io.File(dir, "shot-${System.currentTimeMillis()}.jpg")
                    val uri = androidx.core.content.FileProvider.getUriForFile(activity, activity.packageName + ".files", file)
                    shot = uri
                    activity.startActivityForResult(
                        Intent(MediaStore.ACTION_IMAGE_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT, uri)
                            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION), CAMERA)
                },
                tile(dev.kore.phone.R.drawable.i_file_doc, "File") {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), PICK)
                },
            )
            go.forEachIndexed { i, t -> addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) marginStart = activity.dp(10) }) }
        }
        s = Sheet(activity).show {
            title("Attach")
            custom(tiles)
            custom(activity.label("Up to 12 MB each").apply {
                type(Type.Caption); setTextColor(Tone.faint); gravity = Gravity.CENTER
                setPadding(0, activity.dp(14), 0, 0)
            })
        }
    }

    /** From the activity: a picked or shot file. */
    fun onResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK) return
        val uri = when (requestCode) {
            PICK -> data?.data
            CAMERA -> shot
            else -> null
        } ?: return
        add(uri)
    }

    private fun add(uri: Uri) {
        val resolver = activity.contentResolver
        val mime = resolver.getType(uri) ?: "application/octet-stream"
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: uri.lastPathSegment ?: "file"
        activity.kore.scope.launch {
            val read = runCatching { Uploads.read(resolver, uri, mime) }.getOrNull()
            val item = Attachment(read?.name ?: name, read?.thumb)
            activity.runOnUiThread { attachments.add(item); showChips() }
            if (read == null) { activity.runOnUiThread { attachments.remove(item); showChips(); quiet("Couldn't read that file.") }; return@launch }
            if (read.bytes.size > Uploads.MAX_BYTES) { activity.runOnUiThread { attachments.remove(item); showChips(); quiet("That file is over 12 MB.") }; return@launch }
            val blob = runCatching { link()?.upload(read.name ?: name, read.mime, read.bytes) }
            activity.runOnUiThread {
                val id = blob.getOrNull()
                if (id == null) {
                    attachments.remove(item)
                    val why = blob.exceptionOrNull()?.message?.takeIf { it.isNotBlank() }?.take(60) ?: "the Mac didn't take it"
                    quiet("Couldn't attach ${item.name}: $why.")
                } else item.blobId = id
                showChips()
            }
        }
    }

    /** The attachments as 52 thumbnails (radius 12), each with its × as a 20 circle on `l3`; a file shows its icon. */
    private fun showChips() {
        chips.removeAllViews()
        for (a in attachments) {
            val tile = android.widget.FrameLayout(activity).apply {
                clipChildren = false
                alpha = if (a.blobId != null) 1f else 0.6f
            }
            tile.addView(ImageView(activity).apply {
                background = activity.shape(Tone.l2, 12, Tone.hair2)
                clipToOutline = true
                contentDescription = a.name
                if (a.thumb != null) { setImageBitmap(a.thumb); scaleType = ImageView.ScaleType.CENTER_CROP }
                else {
                    setImageResource(dev.kore.phone.R.drawable.i_file_doc)
                    imageTintList = android.content.res.ColorStateList.valueOf(Tone.b200)
                    scaleType = ImageView.ScaleType.CENTER_INSIDE
                    val pad = activity.dp(14)
                    setPadding(pad, pad, pad, pad)
                }
            }, android.widget.FrameLayout.LayoutParams(activity.dp(52), activity.dp(52)).apply { topMargin = activity.dp(5); marginEnd = activity.dp(5) })
            tile.addView(ImageView(activity).apply {
                setImageResource(dev.kore.phone.R.drawable.i_x)
                imageTintList = android.content.res.ColorStateList.valueOf(Tone.text)
                val pad = activity.dp(4)
                setPadding(pad, pad, pad, pad)
                background = android.graphics.drawable.GradientDrawable().apply {
                    shape = android.graphics.drawable.GradientDrawable.OVAL
                    setColor(Tone.l3)
                    setStroke(activity.dp(2), Tone.l1)
                }
                contentDescription = "Remove ${a.name}"
                setOnClickListener { attachments.remove(a); showChips() }
            }, android.widget.FrameLayout.LayoutParams(activity.dp(22), activity.dp(22), Gravity.TOP or Gravity.END))
            chips.addView(tile, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = activity.dp(3) })
        }
        chipsRow.visibility = if (attachments.isEmpty()) View.GONE else View.VISIBLE
        refreshAction()
    }

    // The "/" menu: the chat's commands, filtered by what follows the slash.

    private fun showSlash() {
        if (!hasCap("commands")) { slashList.removeAllViews(); slashList.visibility = View.GONE; return }
        val text = field.text.toString()
        val match = Commands.filter(chat?.objs("commands").orEmpty().mapNotNull { c ->
            c.str("name")?.let { it to (c.str("description") ?: "") }
        }, text)
        slashList.removeAllViews()
        for ((name, description) in match) {
            slashList.addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(activity.dp(14), activity.dp(10), activity.dp(14), activity.dp(10))
                pressFill(null, Tone.l2, Radius.menuRow)
                addView(activity.label("/$name").apply { type(Type.Mono); setTextColor(Tone.text) })
                if (description.isNotEmpty()) addView(activity.label(description).apply { type(Type.Caption); setTextColor(Tone.faint); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                setOnClickListener {
                    field.setText("/$name ")
                    field.setSelection(field.text.length)
                }
            })
        }
        slashScroll.visibility = if (match.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun stop() {
        val l = link() ?: return quiet("Not connected")
        pending[l.stop(chatId)] = "stop"
    }

    // Modes

    private fun modes(chat: JsonObject): List<JsonObject> {
        val providers = link()?.welcome?.value?.objs("providers") ?: return emptyList()
        return providers.firstOrNull { it.str("id") == chat.str("provider") }?.objs("modes").orEmpty()
    }

    private fun modeLabel(chat: JsonObject, id: String?): String? =
        modes(chat).firstOrNull { it.str("id") == id }?.str("label") ?: id

    /**
     * The mode pill's one sheet (decision 4): the modes (those above what the phone may choose
     * stay faint), the Plan switch where the CLI has one, then model, effort and fast where the
     * model offers them. Its corners take the mode's colour.
     */
    private fun chooseMode() {
        if (chat == null) return
        openLive { modeSheet() }
    }

    private fun openLive(build: Sheet.() -> Unit) {
        val s = Sheet(activity)
        live += s
        s.onDismiss { live.remove(s) }
        s.show(build)
    }

    /** The chat's options, one sheet (option B): model and effort, mode, Arsenal. */
    private fun Sheet.modeSheet() {
        val chat = chat ?: return
        val current = chat.obj("mode")
        corner = modeColor(current?.get("level").int())
        modelPart(chat)
        val allowed = chat.strs("allowedModeIds")
        val offered = chat.strs("modeIds")
        val modes = modes(chat).filter { it.str("id") in offered || it.str("id") == current?.str("id") }.sortedBy { it["level"].int() ?: 1 }
        val provider = link()?.welcome?.value?.objs("providers")?.firstOrNull { it.str("id") == chat.str("provider") }
        section("Mode")
        provider?.obj("planToggle")?.let { plan ->
            val on = current?.bool("planOn") == true
            toggle(plan.str("label") ?: "Plan", on) { run("plan", dev.kore.link.node.Control.setPlan(chatId, it)) }
        }
        for (m in modes) {
            val id = m.str("id") ?: continue
            val level = m["level"].int() ?: 1
            // Above what the phone may choose but at most Auto: a raise, with the fingerprint.
            val raise = id !in allowed && level <= RAISE_CAP
            item(m.str("label") ?: id, dot = modeColor(level), checked = id == current?.str("id"), enabled = id in allowed || raise,
                detail = if (raise && id != current?.str("id")) "fingerprint" else null, tag = "mode $id") {
                if (id == current?.str("id")) return@item
                if (raise) { dismiss(); raisePrompt(m.str("label") ?: id, id) } else { run("mode", modeCmd(id)); say("Switching mode…") }
            }
        }
        arsenalPart(chat)
    }

    /**
     * Model and effort, at the top of the options sheet (the picker, take 1): one row per family
     * with its versions as chips, the chat's own lit, then one effort segment for that model with
     * the levels it doesn't offer struck. The lists are the CLI's own (`clis`).
     */
    private fun Sheet.modelPart(chat: JsonObject) {
        val controls = chat.obj("controls") ?: return
        val provider = chat.str("provider")
        val models = ControlModel.models(snapshot, provider)
        val modelId = want["model"] ?: controls.str("modelId")
        if (models.isNotEmpty()) {
            section("Model")
            for (f in ControlModel.families(models)) family(f.name, f.versions, modelId) { id ->
                pick("model", id)
                // The effort the Mac will settle on for it, shown at once.
                val scale = ControlModel.efforts(snapshot, provider, models.firstOrNull { it.str("id") == id }).map { it.level }
                val offered = models.firstOrNull { it.str("id") == id }?.strs("efforts").orEmpty()
                ControlModel.effortFallback(want["effort"] ?: controls.str("effort"), offered, scale)?.let { want["effort"] = it }
                live.forEach { if (it.isShowing) it.refresh() }
            }
        }
        val model = models.firstOrNull { it.str("id") == modelId }
        val efforts = ControlModel.efforts(snapshot, provider, model)
        if (efforts.isNotEmpty()) {
            section("Effort")
            segmented(efforts.map { it.level to ControlModel.word(it.level) }, want["effort"] ?: controls.str("effort"),
                off = efforts.filter { !it.offered }.map { it.level }.toSet()) { pick("effort", it) }
        }
        if (model?.bool("fast") == true || controls.bool("fastOffered")) {
            val on = want["fast"]?.toBoolean() ?: controls.bool("fast")
            toggle("Fast mode", on) { pick("fast", it.toString()) }
        }
    }

    /** Arsenal at the foot of the options sheet: its tiers in one segment, a raise marked; the reason when it can't. */
    private fun Sheet.arsenalPart(chat: JsonObject) {
        if (!chat.containsKey("arsenal") && snapshot?.obj("mac")?.containsKey("arsenalTiers") != true) return
        val C = dev.kore.link.node.Control
        val current = chat.str("arsenal") ?: "off"
        section("Arsenal")
        chat.str("arsenalUnavailable")?.let { why ->
            custom(activity.label(why, 13f, K.faint).apply { setPadding(activity.dp(4), activity.dp(2), activity.dp(4), activity.dp(8)) })
            return
        }
        val tiers = arsenalTiers()
        segmented(tiers.map { it to arsenalShort(it) }, current, marked = tiers.filter { C.arsenalRaises(current, it) }.toSet()) { t ->
            if (C.arsenalRaises(current, t)) { dismiss(); raisePrompt(C.arsenalName(t), "arsenal.$t") } else run("arsenal", C.setArsenal(chatId, t))
        }
        if (current != "off") item("Stop all", glyph = "■", danger = true, tag = "arsenal stop") { run("arsenalStop", C.arsenalStopAll()) }
    }

    /** A tier's name short enough for a quarter of the segment; the raise sheet says it in full. */
    private fun arsenalShort(tier: String) = when (tier) {
        "own" -> "Act lim."
        "drive" -> "Unlim."
        else -> dev.kore.link.node.Control.arsenalName(tier)
    }

    /** The Mac's tier colours: Read b200, Act limited b400, Act unlimited b300. */

    private fun modeCmd(id: String) = JsonObject(mapOf("type" to JsonPrimitive("chat.setMode"), "chatId" to JsonPrimitive(chatId), "modeId" to JsonPrimitive(id)))

    /** A model, effort or fast choice: shown at once, sent, and undone if the Mac says no. */
    private fun pick(what: String, value: String) {
        want[what] = value
        val C = dev.kore.link.node.Control
        run(what, when (what) {
            "model" -> C.setModel(chatId, value)
            "effort" -> C.setEffort(chatId, value)
            "fast" -> C.setFast(chatId, value.toBoolean())
            else -> C.setAutoCompact(chatId, value.toIntOrNull())
        })
        live.forEach { if (it.isShowing) it.refresh() }
    }

    /** Sends a 1.2 command from this chat; its result comes back through [result]. */
    private fun run(kind: String, cmd: JsonObject) {
        val l = link() ?: return quiet("Not connected")
        pending[l.command(cmd)] = kind
    }

    private fun controlResult(kind: String, r: JsonObject) {
        if (r.bool("ok")) {
            when (kind) {
                "fork" -> r.str("chatId")?.let { id ->
                    activity.startActivity(Intent(activity, ChatActivity::class.java).putExtra("chat", id))
                } ?: quiet("Forked on the Mac")
                "close" -> activity.finish()
                "select" -> quiet("Shown on the Mac")
                "compact" -> quiet("Compacting…")
                "revert" -> quiet("Reverted")
                "sendAtReset" -> quiet("")
                "rename" -> quiet("")
                else -> Unit
            }
            live.forEach { if (it.isShowing) it.say("") }
            return
        }
        val code = r.str("code")
        // No fingerprint given: nothing changed, nothing to say.
        if (code == "cancelled") return
        if (kind == "close" && code == "confirm.close") {
            activity.confirmClose("${chat?.str("title") ?: "This chat"} is working. Closing stops it.") { run("close", dev.kore.link.node.Control.close(chatId, force = true)) }
            return
        }
        if (kind in setOf("model", "effort", "fast", "autoCompact")) want.remove(kind)
        val words = if (code == "denied.raiseMode") r.str("message") ?: refusalWords(code) else refusalWords(code)
        val sheet = live.lastOrNull { it.isShowing }
        if (sheet != null) { sheet.say(words); sheet.refresh() } else quiet(words)
    }

    // The chat's ⋮ sheet (frame 1): rename, compact, auto-compact, show on the Mac, close.

    fun openMenu() {
        if (chat == null) return
        openLive { menuSheet() }
    }

    private fun Sheet.menuSheet() {
        val chat = chat ?: return
        val can = chat.obj("can")
        val controls = chat.obj("controls")
        fun has(key: String) = can?.containsKey(key) == true
        if (has("rename")) item("Rename…", glyph = "✎", enabled = can!!.bool("rename")) { dismiss(); rename() }
        if (has("compact") || controls != null) {
            val pct = controls?.get("contextPct").int()
            val detail = if (controls?.bool("compacting") == true) "compacting…" else pct?.let { "Context $it%" }
            item("Compact now", glyph = "◔", detail = detail, enabled = can?.bool("compact") == true) { dismiss(); compactSheet() }
        }
        if (controls != null) {
            val at = want["autoCompact"]?.let { it.toIntOrNull() } ?: if (want["autoCompact"] == "off") null else controls["autoCompactAt"].int()
            item("Auto-compact", glyph = "⤓", detail = at?.let { "at $it%" } ?: "Off", chevron = true) { dismiss(); compactSheet() }
        }
        if (link().hasControl(snapshot)) item("Show on the Mac", glyph = "⇢") { run("select", dev.kore.link.node.Control.select(chatId)); dismiss() }
        if (has("close")) item("Close tab", glyph = "×", danger = true, enabled = can!!.bool("close")) {
            dismiss()
            val working = chat.bool("running") || chat.str("state") == "working"
            if (working) activity.confirmClose("${chat.str("title") ?: "This chat"} is working. Closing stops it.") { run("close", dev.kore.link.node.Control.close(chatId, force = true)) }
            else run("close", dev.kore.link.node.Control.close(chatId))
        }
    }

    // Arsenal (link 1.3): its tiers are a segment at the foot of the options sheet (`arsenalPart`).

    /** Kore's tiers, lowest first, as the Mac offers them (never `full`). */
    private fun arsenalTiers(): List<String> =
        snapshot?.obj("mac")?.strs("arsenalTiers")?.filter { it in dev.kore.link.node.Control.ARSENAL_TIERS }?.takeIf { it.isNotEmpty() }
            ?: dev.kore.link.node.Control.ARSENAL_TIERS

    /**
     * Raising (a mode, or an Arsenal tier as `arsenal.<tier>`): one line saying what it lets the
     * chat do, then the fingerprint, signed over this link's binding and the node's nonce.
     */
    private fun raisePrompt(label: String, modeId: String) {
        lateinit var s: Sheet
        s = Sheet(activity, KS.danger).show {
            title("Raise to $label?", "The chat may then act without asking, up to $label. Your fingerprint confirms it.")
            buttons("Raise") { s.dismiss(); raise(if (modeId.startsWith("arsenal.")) "arsenal" else "mode", modeId) }
        }
    }

    private fun raise(kind: String, modeId: String) {
        val l = link() ?: return quiet("Not connected")
        activity.kore.scope.launch {
            val r = l.raise(chatId, modeId)
            activity.runOnUiThread { controlResult(kind, r) }
        }
    }

    private fun rename() {
        val chat = chat ?: return
        lateinit var s: Sheet
        s = Sheet(activity).show {
            title("Rename")
            val f = field("Title", chat.str("title").orEmpty())
            buttons("Rename") {
                val t = f.text.toString().trim()
                if (t.isEmpty()) return@buttons say("A title can't be empty.")
                run("rename", dev.kore.link.node.Control.rename(chatId, t)); s.dismiss()
            }
        }
    }

    /** Frame 1's third phone: the auto-compact point (the Mac's notches), then Compact with optional words. */
    private fun compactSheet() {
        var words = ""
        lateinit var s: Sheet
        s = Sheet(activity).show {
            val chat = chat ?: return@show
            val controls = chat.obj("controls")
            title("Auto-compact", "Kore compacts between turns once the context passes this point.")
            val at = want["autoCompact"] ?: controls?.get("autoCompactAt").int()?.toString() ?: "off"
            segmented(listOf("off" to "Off") + listOf(50, 60, 70, 80, 90).map { "$it" to "$it%" }, at, enabled = controls != null) { v ->
                words = s.body.findViewWithTag<EditText>("kore.compact")?.text?.toString() ?: words
                want["autoCompact"] = v
                run("autoCompact", dev.kore.link.node.Control.setAutoCompact(chatId, v.toIntOrNull()))
                s.refresh()
            }
            section("Compact now")
            val f = field("What the summary should keep (optional)", words).apply { tag = "kore.compact" }
            buttons("Compact") {
                if (chat.obj("can")?.bool("compact") != true) return@buttons say("Kore compacts between turns: wait for this one to end.")
                run("compact", dev.kore.link.node.Control.compact(chatId, f.text.toString())); s.dismiss()
            }
        }
    }

    private fun sendAtReset() {
        val text = field.text.toString().trim()
        if (text.isEmpty()) return quiet("Write the message that goes at the reset.")
        if (attachments.any { it.blobId == null && !it.failed }) return quiet("Waiting for the attachments to upload…")
        val blobs = attachments.mapNotNull { it.blobId }
        showingDraft = true
        field.setText("")
        showingDraft = false
        attachments.clear()
        showChips()
        run("sendAtReset", dev.kore.link.node.Control.sendAtReset(chatId, text, blobs))
        drafts.sent(clock())
        scheduleDraft()
    }

    /** From the transcript: rescue actions, fork. */
    fun rescue(action: String, turnId: String? = null) {
        val C = dev.kore.link.node.Control
        when (action) {
            "retry" -> run("retry", C.retry(chatId))
            "retryTurn" -> run("retry", C.retry(chatId, turnId))
            "stop" -> stop()
            "continue" -> run("continue", C.continueTurn(chatId))
            "cancelContinue" -> run("cancelContinue", C.cancelContinue(chatId))
        }
    }

    fun fork(entryId: String, after: Boolean) {
        quiet("Forking…")
        run("fork", dev.kore.link.node.Control.fork(chatId, entryId, after))
    }

    /** Whether a turn runs now: going back waits for it to stop (the Mac's rule). */
    val turnRunning: Boolean get() = running

    /**
     * "Revert to here", the Mac's rollback: asks first (what follows leaves the chat; files stay
     * as they are), never under a running turn.
     */
    fun revert(entryId: String, after: Boolean) {
        if (running) return quiet("Stop the turn first, then revert.")
        lateinit var s: Sheet
        s = Sheet(activity, K.err).show {
            title("Revert to here?", revertLine(prompt = !after))
            buttons("Revert", danger = true) {
                s.dismiss()
                run("revert", dev.kore.link.node.Control.rollback(chatId, entryId, after))
            }
        }
    }

    // Cards

    /**
     * The need-you card (spec §5): "Needs you" over its title (Headline). A permission shows what it
     * runs in a mono block (the owner never allows without seeing it), then Deny and Allow. A
     * question lists its options as rows; with one single-choice question a tap answers, else
     * rows toggle and Submit sends them. "Something else…" opens a field for the CLI's free answer.
     */
    private fun showCard(card: JsonObject?) {
        sheet.removeAllViews()
        cardKeep = null
        cardButtons.removeAllViews()
        cardButtons.visibility = View.GONE
        if (card == null) { cardBox.visibility = View.GONE; return }
        cardBox.visibility = View.VISIBLE
        val cardId = card.str("id") ?: return
        val dp = activity::dp
        fun lp(top: Int = 0) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(top) }
        sheet.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(activity.point(Tone.warn, 6))
            // The tool or ask it comes from ("Bash") follows the overline, quiet.
            val from = card.str("title")?.takeIf { card.str("detail")?.isNotBlank() == true }
            addView(activity.label(if (from != null) "Needs you · $from" else "Needs you").apply {
                type(Type.Caption)
                typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, 500, false)
                setTextColor(Tone.warn)
                setPadding(dp(6), 0, 0, 0)
            })
        }, lp())
        // Its headline is what it asks ("Run a command?"), the Mac's detail, else its title.
        val title = card.str("detail")?.takeIf { it.isNotBlank() }?.let { if (card.str("kind") == "permission" && !it.endsWith("?")) "$it?" else it }
            ?: card.str("title") ?: "Needs you"
        sheet.addView(activity.label(title).apply { type(Type.Headline); setTextColor(Tone.text) }, lp(6))
        val permission = card.str("kind") == "permission"
        val body = card.str("body")?.takeIf { it.isNotBlank() && it != title }
        body?.let {
            val shown = activity.label(it.take(600))
            if (permission) cardKeep = shown
            sheet.addView(shown.apply {
                if (permission) {
                    type(Type.Mono)
                    setTextColor(Tone.text)
                    background = activity.shape(Tone.well, 12, Tone.hair)
                    setPadding(dp(14), dp(10), dp(14), dp(10))
                } else { type(Type.Callout); setTextColor(Tone.dim) }
                setTextIsSelectable(true)
            }, lp(10))
        }
        if (card.str("kind") == "signIn") {
            sheet.addView(activity.label("Answer this on the Mac.").apply { type(Type.Callout); setTextColor(Tone.faint) }, lp(10))
            return
        }
        val actions = card.objs("actions").filter { a ->
            // Only what the phone may do: the Mac refuses the rest anyway.
            val id = a.str("id")
            id != null && !a.bool("refused") && id != "allowAlways" && id != "approvePlanAcceptEdits"
        }
        val questions = card.objs("questions")
        val canSubmit = actions.any { it.str("id") == "submitAnswers" }
        // One single-choice question: a tap on an option is the answer.
        val tapAnswers = canSubmit && questions.size == 1 && !questions[0].bool("multiple")
        val chosen = LinkedHashMap<String, MutableList<String>>()
        val others = LinkedHashMap<String, EditText>()
        for (q in questions) {
            val qid = q.str("id") ?: q.str("text") ?: continue
            val multiple = q.bool("multiple")
            q.str("text")?.takeIf { it.isNotBlank() && it != title }?.let {
                sheet.addView(activity.label(it).apply { type(Type.Body); setTextColor(Tone.text) }, lp(if (sheet.childCount > 2) 14 else 8))
            }
            val rows = ArrayList<Pair<String, LinearLayout>>()
            fun mark() = rows.forEach { (label, row) ->
                val on = chosen[qid]?.contains(label) == true
                row.pressFill(if (on) Tone.accentFill else Tone.l2, Tone.l3, Radius.row, if (on) Tone.b200 else null)
                (row.getChildAt(1) as ImageView).visibility = if (on || tapAnswers) View.VISIBLE else View.INVISIBLE
            }
            for (o in q.objs("options")) {
                val label = o.str("label") ?: continue
                val row = optionRow(label, o.str("description"), if (tapAnswers) dev.kore.phone.R.drawable.i_chevron else dev.kore.phone.R.drawable.i_check)
                row.setOnClickListener {
                    if (tapAnswers) return@setOnClickListener answer(cardId, "submitAnswers", mapOf(qid to listOf(label)))
                    val list = chosen.getOrPut(qid) { mutableListOf() }
                    if (list.contains(label)) list.remove(label) else { if (!multiple) list.clear(); list.add(label) }
                    mark()
                }
                rows += label to row
                sheet.addView(row, lp(8))
            }
            mark()
            if (q.bool("other")) {
                val secret = q.bool("secret")
                lateinit var other: View
                other = activity.label("Something else…").apply {
                    type(Type.Body)
                    setTextColor(Tone.faint)
                    setPadding(dp(14), dp(12), dp(14), dp(12))
                    pressFill(null, Tone.l2, Radius.row, Tone.hair2)
                    setOnClickListener {
                        // The field takes its place; with a single question, Send answers with it.
                        val at = sheet.indexOfChild(other)
                        sheet.removeView(other)
                        val input = EditText(activity).apply {
                            type(Type.Body)
                            setTextColor(Tone.text)
                            setHintTextColor(Tone.faint)
                            hint = "Your answer"
                            inputType = if (secret) android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD else ComposerKeys.INPUT_TYPE
                            background = activity.shape(Tone.bg, Radius.row, Tone.focus)
                            setPadding(dp(14), dp(12), dp(14), dp(12))
                            minLines = 1
                            maxLines = 4
                        }
                        others[qid] = input
                        sheet.addView(input, at, lp(8))
                        // Send joins the card's pinned buttons, beside Skip, so the keyboard never hides it.
                        if (tapAnswers) {
                            cardButtons.visibility = View.VISIBLE
                            (cardButtons.layoutParams as LinearLayout.LayoutParams).topMargin = dp(12)
                            cardButtons.addView(activity.button("Send", Btn.Primary) {
                                val text = input.text.toString().trim()
                                if (text.isNotEmpty()) answer(cardId, "submitAnswers", mapOf(qid to listOf(text)))
                            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (cardButtons.childCount > 0) marginStart = dp(10) })
                        }
                        input.requestFocus()
                        activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.showSoftInput(input, 0)
                    }
                }
                sheet.addView(other, lp(8))
            }
        }
        // The card's buttons, side by side (Deny secondary, Allow primary); a tap-answered question keeps only Skip, quiet.
        val shown = if (tapAnswers) actions.filter { it.str("id") != "submitAnswers" } else actions
        if (shown.isEmpty()) return
        val row = cardButtons
        // Primary last (at the thumb's side), as the spec's Deny · Allow.
        shown.sortedBy { if (it.str("style") == "primary") 1 else 0 }.forEachIndexed { i, a ->
            val id = a.str("id")!!
            // Spec §5: Deny is secondary beside Allow, even where the Mac calls it destructive.
            val role = when {
                a.str("style") == "primary" -> Btn.Primary
                tapAnswers -> Btn.Quiet
                else -> Btn.Secondary
            }
            row.addView(activity.button(a.str("label") ?: id, role) {
                val answers = if (id != "submitAnswers") null else LinkedHashMap<String, List<String>>().apply {
                    chosen.forEach { (k, v) -> put(k, v.toList()) }
                    others.forEach { (k, f) -> f.text.toString().trim().takeIf { it.isNotEmpty() }?.let { put(k, (get(k) ?: emptyList()) + it) } }
                }
                answer(cardId, id, answers)
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) marginStart = dp(10) })
        }
        row.visibility = View.VISIBLE
        (row.layoutParams as LinearLayout.LayoutParams).topMargin = dp(if (permission) 14 else 12)
    }

    /** A question's option (spec §5): `l2`, radius 14, padding 12 × 14; its label (Body medium), one Callout line, then [end]. */
    private fun optionRow(label: String, description: String?, end: Int) = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
        contentDescription = if (description.isNullOrBlank()) label else "$label. $description"
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(activity.label(label).apply { type(Type.BodyMedium); setTextColor(Tone.text) })
            if (!description.isNullOrBlank()) addView(activity.label(description).apply {
                type(Type.Callout); setTextColor(Tone.dim); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
            })
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(ImageView(activity).apply {
            setImageResource(end)
            imageTintList = android.content.res.ColorStateList.valueOf(if (end == dev.kore.phone.R.drawable.i_check) Tone.accent else Tone.faint)
        }, LinearLayout.LayoutParams(activity.dp(18), activity.dp(18)).apply { marginStart = activity.dp(12) })
    }

    private fun answer(cardId: String, action: String, answers: Map<String, List<String>>?) {
        val go: () -> Unit = {
            val l = link()
            if (l == null) quiet("Not connected") else { activity.kore.scope.launch {
                val id = runCatching { l.answer(chatId, cardId, action, answers) }
                activity.runOnUiThread {
                    id.fold(
                        onSuccess = { if (it == null) quiet("That card changed. Look again.") else { pending[it] = "answer"; quiet("") } },
                        onFailure = { quiet("Couldn't send that answer. Try again.") },
                    )
                }
            } }
        }
        // A plain tap answers (owner, 2026-11-14); the fingerprint is only for raises.
        go()
    }

    companion object {
        /** The highest mode level a raise from the phone asks for (Auto); Bypass and Full access never. */
        const val RAISE_CAP = 3
        const val PICK = 41
        /** What a paste attaches rather than inserts: any file but plain text. */
        val PASTE_TYPES = arrayOf("image/*", "video/*", "audio/*", "application/*")
        const val CAMERA = 42
        /** Commands of KoreLink 1.2 sent from a chat; their results go to [controlResult]. */
        val CONTROL = setOf("mode", "plan", "model", "effort", "fast", "autoCompact", "compact", "rename", "close", "select", "fork",
            "retry", "continue", "cancelContinue", "sendAtReset", "arsenal", "arsenalStop", "revert")
    }

    /** A scroll that grows with its content up to a cap, so a long card never pushes the composer away. */
    private class MaxHeightScroll(context: android.content.Context, private val max: (Int) -> Int) : ScrollView(context) {
        /** [max] gets the height its parent offers (all of it when unbounded). */
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val room = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED) Int.MAX_VALUE / 2 else MeasureSpec.getSize(heightMeasureSpec)
            super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(max(room), MeasureSpec.AT_MOST))
        }
    }
}

/**
 * Arsenal's tier colours, the Mac's (Theme.Arsenal): Read (watch) #A3C3DC, Act limited (own)
 * #3C97DD, Act unlimited (drive) #6AB1E7, Full #E1C08D. ARGB, for the mark's tint.
 */
fun arsenalTint(tier: String?): Int = when (tier) {
    "watch" -> Tone.b200
    "own" -> Tone.b400
    "full" -> Tone.warn
    else -> Tone.accent
}

/**
 * The Revert sheet's line (design spec §8), as this revert does it: the chat goes back, and on a
 * prompt its text returns to the field. Files aren't touched by it, so the spec's files line never shows.
 */
fun revertLine(prompt: Boolean): String =
    if (prompt) "The chat goes back to before this message. Its text returns to the field."
    else "The chat goes back to this answer; what came after it leaves."
