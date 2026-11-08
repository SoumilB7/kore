package dev.kore.phone.ui

import android.app.Activity
import android.app.Dialog
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
import android.view.inputmethod.EditorInfo
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
    private val sheet = activity.column(14).apply { background = activity.rounded(K.surface, 14, K.line) }
    private val sheetScroll = MaxHeightScroll(activity, activity.resources.displayMetrics.heightPixels * 2 / 5).apply {
        addView(sheet)
        visibility = View.GONE
    }
    private val status = activity.label("", 12f, K.faint).apply {
        setOnClickListener { retry() }
        maxLines = 2
        ellipsize = android.text.TextUtils.TruncateAt.END
        setPadding(activity.dp(4), 0, activity.dp(4), activity.dp(6))
        visibility = View.GONE
    }
    private val modePill = activity.label("", 12f, K.dim).apply {
        background = activity.rounded(K.surface, 16, K.line)
        setPadding(activity.dp(10), activity.dp(7), activity.dp(10), activity.dp(7))
        maxLines = 1
        contentDescription = "Mode"
        setOnClickListener { chooseMode() }
        visibility = View.GONE
    }
    /** At a plan limit: the draft goes when the limit resets (C7), as the Mac's ring beside Send. */
    private val ring = activity.label("⟳", 15f, K.warn).apply {
        gravity = Gravity.CENTER
        background = activity.rounded(android.graphics.Color.TRANSPARENT, 16, K.warn)
        contentDescription = "Send at reset"
        visibility = View.GONE
        setOnClickListener { sendAtReset() }
    }
    private val field = EditText(activity).apply {
        hint = "Message"
        setHintTextColor(K.faint)
        setTextColor(K.text)
        textSize = 15f
        background = null
        setPadding(activity.dp(14), activity.dp(10), activity.dp(14), activity.dp(4))
        // No learning or suggestions from what is typed here.
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        minLines = 1
        maxLines = 6
        isVerticalScrollBarEnabled = true
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "Message"
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun afterTextChanged(s: Editable?) { refreshAction(); showSlash() }
        })
    }
    private val action = activity.label("↑", 18f, K.bg, bold = true).apply {
        gravity = Gravity.CENTER
        contentDescription = "Send"
        setOnClickListener { if (running) stop() else send() }
    }

    private val attach = ImageView(activity).apply {
        setImageResource(dev.kore.phone.R.drawable.ic_attach)
        setPadding(activity.dp(7), activity.dp(7), activity.dp(7), activity.dp(7))
        contentDescription = "Attach"
        setOnClickListener { if (uploadsOn()) chooseAttachment() else quiet("Uploads arrive with Kore's next update.") }
    }
    private val chips = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val chipsRow = HorizontalScrollView(activity).apply {
        isHorizontalScrollBarEnabled = false
        addView(chips)
        visibility = View.GONE
    }
    private val slashList = activity.column().apply { background = activity.rounded(K.surface, 12, K.line) }
    private val slashScroll = MaxHeightScroll(activity, activity.dp(220)).apply {
        addView(slashList)
        visibility = View.GONE
    }

    val view: View = activity.column().apply {
        setPadding(activity.dp(12), activity.dp(6), activity.dp(12), activity.dp(10))
        addView(sheetScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = activity.dp(8) })
        addView(slashScroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = activity.dp(8) })
        addView(status)
        addView(chipsRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = activity.dp(8) })
        // One container, as Kore's composer on the Mac: the message on top, then a slim bar with
        // attach and the mode on the left and Send (Stop while running) on the right.
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = activity.rounded(K.surface, 14, K.line)
            addView(field, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(activity.dp(6), 0, activity.dp(6), activity.dp(6))
                addView(attach, LinearLayout.LayoutParams(activity.dp(36), activity.dp(36)))
                addView(modePill, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                    marginStart = activity.dp(4)
                })
                addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f))
                addView(ring, LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)).apply { marginEnd = activity.dp(8) })
                addView(action, LinearLayout.LayoutParams(activity.dp(36), activity.dp(36)))
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, activity.dp(42)))
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private var chat: JsonObject? = null
    private var snapshot: JsonObject? = null
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
        canSend = chat?.obj("can")?.bool("send") ?: false
        running = chat?.bool("running") == true
        // The field is always there and always takes a tap; only Send waits for the chat.
        field.alpha = if (chat == null || canSend) 1f else 0.6f
        val mode = chat?.let { modeLabel(it, it.obj("mode")?.str("id")) }
        modePill.text = mode?.let { m ->
            android.text.SpannableStringBuilder().append("●", android.text.style.ForegroundColorSpan(modeColor(chat.obj("mode")?.get("level").int())), 0).append("  $m")
        } ?: ""
        modePill.visibility = if (mode != null) View.VISIBLE else View.GONE
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

    private fun refreshAction() {
        val atLimit = ControlModel.limitReset(chat?.obj("rescue")) != null && chat?.obj("can")?.bool("sendAtReset") == true
        ring.visibility = if (atLimit) View.VISIBLE else View.GONE
        ring.alpha = if (field.text.isNotBlank()) 1f else 0.45f
        if (running) {
            action.text = "■"
            action.textSize = 14f
            action.contentDescription = "Stop"
            action.background = activity.rounded(K.err, 18)
            action.alpha = 1f
            action.isEnabled = true
        } else {
            action.text = "↑"
            action.textSize = 18f
            action.contentDescription = "Send"
            val ready = canSend && field.text.isNotBlank()
            action.background = activity.rounded(if (ready) K.accent else K.line, 18)
            action.alpha = if (ready) 1f else 0.6f
            action.isEnabled = ready
        }
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
        if (text.isEmpty() || !canSend) return
        val l = link() ?: return quiet("Not connected")
        if (attachments.any { it.blobId == null && !it.failed }) return quiet("Waiting for the attachments to upload…")
        val blobs = attachments.mapNotNull { it.blobId }
        field.setText("")
        attachments.clear()
        showChips()
        val id = l.send(chatId, text, blobs)
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

    private fun chooseAttachment() {
        val dialog = Dialog(activity)
        val list = activity.column(16).apply { background = activity.rounded(K.surface, 16, K.line) }
        fun item(title: String, go: () -> Unit) = list.addView(activity.label(title, 16f, K.text).apply {
            setPadding(activity.dp(4), activity.dp(13), activity.dp(4), activity.dp(13))
            setOnClickListener { dialog.dismiss(); go() }
        })
        item("Photo library") {
            activity.startActivityForResult(Intent(MediaStore.ACTION_PICK_IMAGES), PICK)
        }
        item("Camera") {
            val dir = java.io.File(activity.cacheDir, "shots").apply { mkdirs() }
            val file = java.io.File(dir, "shot-${System.currentTimeMillis()}.jpg")
            val uri = androidx.core.content.FileProvider.getUriForFile(activity, activity.packageName + ".files", file)
            shot = uri
            activity.startActivityForResult(
                Intent(MediaStore.ACTION_IMAGE_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT, uri)
                    .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION), CAMERA)
        }
        item("File") {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), PICK)
        }
        dialog.setContentView(list)
        dialog.window?.apply {
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
            setGravity(Gravity.BOTTOM)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        dialog.show()
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

    private fun showChips() {
        chips.removeAllViews()
        for (a in attachments) {
            val chip = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = activity.rounded(K.surface, 10, K.line)
                setPadding(activity.dp(6), activity.dp(6), activity.dp(8), activity.dp(6))
                alpha = if (a.blobId != null) 1f else 0.6f
            }
            if (a.thumb != null) chip.addView(ImageView(activity).apply {
                setImageBitmap(a.thumb)
                scaleType = ImageView.ScaleType.CENTER_CROP
            }, LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)).apply { marginEnd = activity.dp(6) })
            chip.addView(activity.label(a.name, 12f, K.dim).apply { maxLines = 1; maxWidth = activity.dp(140); ellipsize = android.text.TextUtils.TruncateAt.MIDDLE })
            chip.addView(activity.label("×", 16f, K.dim).apply {
                setPadding(activity.dp(8), 0, activity.dp(2), 0)
                contentDescription = "Remove ${a.name}"
                setOnClickListener { attachments.remove(a); showChips() }
            })
            chips.addView(chip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = activity.dp(6) })
        }
        chipsRow.visibility = if (attachments.isEmpty()) View.GONE else View.VISIBLE
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
                addView(activity.label("/$name", 14f, K.text, mono = true))
                if (description.isNotEmpty()) addView(activity.label(description, 12f, K.faint).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
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

    private fun Sheet.modeSheet() {
        val chat = chat ?: return
        val current = chat.obj("mode")
        corner = modeColor(current?.get("level").int())
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
        val controls = chat.obj("controls") ?: return
        val models = ControlModel.models(snapshot, chat.str("provider"))
        val modelId = want["model"] ?: controls.str("modelId")
        if (models.isNotEmpty()) {
            section("Model")
            for (f in ControlModel.families(models)) {
                val here = modelId in f.ids
                val single = f.versions.size == 1 && f.versions[0].second.isEmpty()
                if (single) {
                    item(f.name, checked = here, tag = "model ${f.name}") { pick("model", f.ids[0]) }
                } else {
                    val open = here || openFamily == f.name
                    item(f.name, chevron = !open, tag = "model ${f.name}") { openFamily = if (openFamily == f.name && !here) null else f.name; refresh() }
                    if (open) chips(f.versions, modelId) { pick("model", it) }
                }
            }
        }
        val model = models.firstOrNull { it.str("id") == modelId }
        val efforts = model?.strs("efforts").orEmpty()
        if (efforts.isNotEmpty()) {
            section("Effort")
            segmented(efforts.map { it to ControlModel.word(it) }, want["effort"] ?: controls.str("effort")) { pick("effort", it) }
        }
        if (model?.bool("fast") == true || controls.bool("fastOffered")) {
            val on = want["fast"]?.toBoolean() ?: controls.bool("fast")
            toggle("Fast mode", on) { pick("fast", it.toString()) }
        }
    }
    private var openFamily: String? = null

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
            val detail = if (controls?.bool("compacting") == true) "compacting…" else pct?.let { "context $it%" }
            item("Compact now", glyph = "◔", detail = detail, enabled = can?.bool("compact") == true) { dismiss(); compactSheet() }
        }
        if (controls != null) {
            val at = want["autoCompact"]?.let { it.toIntOrNull() } ?: if (want["autoCompact"] == "off") null else controls["autoCompactAt"].int()
            item("Auto-compact", glyph = "⤓", detail = at?.let { "at $it%" } ?: "Off", chevron = true) { dismiss(); compactSheet() }
        }
        arsenalRow(chat)
        if (link().hasControl(snapshot)) item("Show on the Mac", glyph = "⇢") { run("select", dev.kore.link.node.Control.select(chatId)); dismiss() }
        if (has("close")) item("Close tab", glyph = "×", danger = true, enabled = can!!.bool("close")) {
            dismiss()
            val working = chat.bool("running") || chat.str("state") == "working"
            if (working) activity.confirmClose("${chat.str("title") ?: "This chat"} is working. Closing stops it.") { run("close", dev.kore.link.node.Control.close(chatId, force = true)) }
            else run("close", dev.kore.link.node.Control.close(chatId))
        }
    }

    // Arsenal (link 1.3): one row with the chat's tier; its sheet lists the Mac's tiers and Stop all.

    /** Kore's tiers, lowest first, as the Mac offers them (never `full`). */
    private fun arsenalTiers(): List<String> =
        snapshot?.obj("mac")?.strs("arsenalTiers")?.filter { it in dev.kore.link.node.Control.ARSENAL_TIERS }?.takeIf { it.isNotEmpty() }
            ?: dev.kore.link.node.Control.ARSENAL_TIERS

    private fun Sheet.arsenalRow(chat: JsonObject) {
        if (!chat.containsKey("arsenal") && snapshot?.obj("mac")?.containsKey("arsenalTiers") != true) return
        val unavailable = chat.str("arsenalUnavailable")
        item("Arsenal", glyph = "ϟ", detail = unavailable ?: dev.kore.link.node.Control.arsenalName(chat.str("arsenal")),
            chevron = unavailable == null, enabled = unavailable == null, tag = "arsenal") { dismiss(); openLive { arsenalSheet() } }
    }

    /** A raise (off counts as lowest) asks for the fingerprint; a lower or Off doesn't. */
    private fun Sheet.arsenalSheet() {
        val chat = chat ?: return
        val C = dev.kore.link.node.Control
        val current = chat.str("arsenal") ?: "off"
        val unavailable = chat.str("arsenalUnavailable")
        section("Arsenal")
        for (t in arsenalTiers()) {
            item(C.arsenalName(t), checked = t == current, enabled = unavailable == null || t == "off", tag = "arsenal $t") {
                if (t == current) return@item
                if (C.arsenalRaises(current, t)) { dismiss(); raisePrompt(C.arsenalName(t), "arsenal.$t") } else run("arsenal", C.setArsenal(chatId, t))
            }
        }
        item("Stop all", glyph = "■", danger = true, tag = "arsenal stop") { run("arsenalStop", C.arsenalStopAll()) }
    }

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
        field.setText("")
        attachments.clear()
        showChips()
        run("sendAtReset", dev.kore.link.node.Control.sendAtReset(chatId, text, blobs))
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


    // Cards

    private fun showCard(card: JsonObject?) {
        sheet.removeAllViews()
        if (card == null) { sheetScroll.visibility = View.GONE; return }
        sheetScroll.visibility = View.VISIBLE
        val cardId = card.str("id") ?: return
        sheet.addView(activity.label(card.str("title") ?: "Needs you", 15f, K.text, bold = true))
        (card.str("detail") ?: card.str("body"))?.let { body ->
            sheet.addView(activity.label(body.take(600), 13f, K.dim, mono = card.str("kind") == "permission").apply {
                setPadding(0, activity.dp(6), 0, activity.dp(4))
            })
        }
        if (card.str("kind") == "signIn") {
            sheet.addView(activity.label("Answer this on the Mac.", 13f, K.faint))
            return
        }
        // Questions: choose labels per question, then submit them together.
        val chosen = LinkedHashMap<String, MutableList<String>>()
        for (q in card.objs("questions")) {
            val qid = q.str("id") ?: q.str("text") ?: continue
            val multiple = q.bool("multiple")
            sheet.addView(activity.label(q.str("text") ?: "", 14f, K.text).apply { setPadding(0, activity.dp(8), 0, activity.dp(4)) })
            val options = activity.column()
            for (o in q.objs("options")) {
                val label = o.str("label") ?: continue
                options.addView(pill(label, K.bg, K.text) { b ->
                    val list = chosen.getOrPut(qid) { mutableListOf() }
                    if (!multiple) { list.clear(); for (i in 0 until options.childCount) options.getChildAt(i).alpha = 0.55f }
                    if (list.contains(label)) list.remove(label) else list.add(label)
                    b.alpha = if (list.contains(label)) 1f else 0.55f
                }.apply {
                    alpha = 0.55f
                    layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(6) }
                })
            }
            sheet.addView(options)
        }
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            setPadding(0, activity.dp(10), 0, 0)
        }
        for (a in card.objs("actions")) {
            val id = a.str("id") ?: continue
            // Only what the phone may do: the Mac refuses the rest anyway.
            if (a.bool("refused") || id == "allowAlways" || id == "approvePlanAcceptEdits") continue
            val primary = a.str("style") == "primary"
            row.addView(pill(a.str("label") ?: id, if (primary) K.accent else K.bg, if (primary) K.bg else K.text) {
                answer(cardId, id, if (id == "submitAnswers") chosen else null)
            }.apply { layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = activity.dp(8) } })
        }
        sheet.addView(row)
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

    private fun pill(title: String, fill: Int, ink: Int, onTap: (TextView) -> Unit): TextView =
        activity.label(title, 14f, ink, bold = true).apply {
            gravity = Gravity.CENTER
            background = activity.rounded(fill, 10, if (fill == K.accent) null else K.line)
            setPadding(activity.dp(16), activity.dp(10), activity.dp(16), activity.dp(10))
            setOnClickListener { onTap(this) }
        }

    companion object {
        /** The highest mode level a raise from the phone asks for (Auto); Bypass and Full access never. */
        const val RAISE_CAP = 3
        const val PICK = 41
        const val CAMERA = 42
        /** Commands of KoreLink 1.2 sent from a chat; their results go to [controlResult]. */
        val CONTROL = setOf("mode", "plan", "model", "effort", "fast", "autoCompact", "compact", "rename", "close", "select", "fork",
            "retry", "continue", "cancelContinue", "sendAtReset", "arsenal", "arsenalStop")
    }

    /** A scroll that grows with its content up to a cap, so a long card never pushes the composer away. */
    private class MaxHeightScroll(context: android.content.Context, private val max: Int) : ScrollView(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
            super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(max, MeasureSpec.AT_MOST))
    }
}
