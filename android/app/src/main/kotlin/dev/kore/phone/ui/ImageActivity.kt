package dev.kore.phone.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.RectF
import android.net.Uri
import android.os.Bundle
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.FrameLayout
import android.widget.ImageView
import dev.kore.phone.kore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One image, full screen (the composer's attachment or a sent one): pinch or double-tap to zoom,
 * drag to look around, × or Back to close. Decoded once at the screen's size, never larger; a
 * sent image shows its thumbnail at once, then its full picture from the Mac or box. No library.
 */
class ImageActivity : Activity() {
    private lateinit var image: ZoomImage
    private var loading: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        image = ZoomImage(this).apply { contentDescription = intent.getStringExtra(NAME) ?: "Image" }
        val close = barIcon(dev.kore.phone.R.drawable.i_x, "Close").apply {
            imageTintList = android.content.res.ColorStateList.valueOf(Tone.text)
            setOnClickListener { finish() }
            pressFill(null, Tone.l2, 24)
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(android.graphics.Color.BLACK)
            addView(image, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            addView(close, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.START).apply { setMargins(dp(4), dp(4), 0, 0) })
        })
        load()
    }

    override fun onDestroy() {
        loading?.cancel()
        super.onDestroy()
    }

    private fun load() {
        val side = resources.displayMetrics.let { maxOf(it.widthPixels, it.heightPixels) }
        val uri = intent.getStringExtra(URI)?.let(Uri::parse)
        val ref = intent.getStringExtra(REF)
        ref?.let { Thumbs.get(it) }?.let(image::show)
        loading = kore.scope.launch {
            val bitmap = withContext(Dispatchers.IO) {
                runCatching {
                    when {
                        uri != null -> decode(ImageDecoder.createSource(contentResolver, uri), side)
                        ref != null -> {
                            val chat = intent.getStringExtra(CHAT) ?: return@runCatching null
                            val link = kore.mesh.node(intent.getStringExtra("node")) ?: return@runCatching null
                            link.blobGet(chat, ref, "full")?.let { decode(ImageDecoder.createSource(java.nio.ByteBuffer.wrap(it)), side) }
                        }
                        else -> null
                    }
                }.getOrNull()
            }
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                if (bitmap != null) image.show(bitmap)
                else if (ref == null || Thumbs.get(ref) == null) { Quiet.say(this@ImageActivity, "Couldn't open that image."); }
            }
        }
    }

    companion object {
        const val URI = "uri"
        const val CHAT = "chat"
        const val REF = "ref"
        const val NAME = "name"

        /** Decoded to fit [side] on its longer edge (never up), for the screen only. */
        fun decode(source: ImageDecoder.Source, side: Int): Bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val (w, h) = fit(info.size.width, info.size.height, side)
            decoder.setTargetSize(w, h)
        }

        /** [w] × [h] scaled down so the longer edge is at most [side]; as it is when it already fits. */
        fun fit(w: Int, h: Int, side: Int): Pair<Int, Int> {
            val longer = maxOf(w, h)
            if (longer <= side || longer <= 0) return w to h
            val scale = side.toDouble() / longer
            return maxOf(1, (w * scale).toInt()) to maxOf(1, (h * scale).toInt())
        }

        /** Opens a local image (a content URI this app may read). */
        fun open(a: Activity, uri: Uri, name: String?) = a.startActivity(Intent(a, ImageActivity::class.java)
            .putExtra(URI, uri.toString()).putExtra(NAME, name).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))

        /** Opens a sent image: a chat's attachment on the device the activity shows. */
        fun open(a: Activity, chatId: String, ref: String, name: String?) = a.startActivity(Intent(a, ImageActivity::class.java)
            .putExtra(CHAT, chatId).putExtra(REF, ref).putExtra(NAME, name).putExtra("node", a.intent?.getStringExtra("node")))
    }
}

/**
 * An image that fits the screen and zooms 1–5×: pinch, double-tap (2.5× there, back to fit), drag
 * while zoomed. Only its matrix changes; nothing is decoded again.
 */
class ZoomImage(context: Context) : ImageView(context) {
    private val m = Matrix()
    private var scale = 1f
    private val bounds = RectF()

    private val pinch = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            val to = (scale * d.scaleFactor).coerceIn(1f, MAX)
            val by = to / scale
            scale = to
            m.postScale(by, by, d.focusX, d.focusY)
            settle()
            return true
        }
    })

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            if (scale <= 1f) return false
            m.postTranslate(-dx, -dy)
            settle()
            return true
        }
        override fun onDoubleTap(e: MotionEvent): Boolean {
            if (scale > 1f) fit() else { scale = DOUBLE; m.postScale(DOUBLE, DOUBLE, e.x, e.y); settle() }
            return true
        }
    })

    init {
        scaleType = ScaleType.MATRIX
    }

    fun show(bitmap: Bitmap) {
        setImageBitmap(bitmap)
        fit()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        fit()
    }

    @android.annotation.SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        pinch.onTouchEvent(event)
        if (!pinch.isInProgress) gestures.onTouchEvent(event)
        // Zoomed, a drag is the image's, not a swipe of anything around it.
        parent?.requestDisallowInterceptTouchEvent(scale > 1f)
        return true
    }

    /** Centred, as large as fits. */
    private fun fit() {
        val d = drawable ?: return
        if (width == 0 || height == 0 || d.intrinsicWidth <= 0) return
        val s = minOf(width.toFloat() / d.intrinsicWidth, height.toFloat() / d.intrinsicHeight)
        m.setScale(s, s)
        m.postTranslate((width - d.intrinsicWidth * s) / 2f, (height - d.intrinsicHeight * s) / 2f)
        scale = 1f
        imageMatrix = m
    }

    /** Keeps the picture on screen: centred on an axis it doesn't fill, its edges at the view's on one it does. */
    private fun settle() {
        val d = drawable ?: return
        bounds.set(0f, 0f, d.intrinsicWidth.toFloat(), d.intrinsicHeight.toFloat())
        m.mapRect(bounds)
        val dx = when {
            bounds.width() <= width -> width / 2f - bounds.centerX()
            bounds.left > 0 -> -bounds.left
            bounds.right < width -> width - bounds.right
            else -> 0f
        }
        val dy = when {
            bounds.height() <= height -> height / 2f - bounds.centerY()
            bounds.top > 0 -> -bounds.top
            bounds.bottom < height -> height - bounds.bottom
            else -> 0f
        }
        m.postTranslate(dx, dy)
        imageMatrix = m
    }

    private companion object {
        const val MAX = 5f
        const val DOUBLE = 2.5f
    }
}
