package dev.kore.phone.ui

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.View
import android.widget.TextView

/**
 * The phone's look (design spec, 2026-11-17): Kore's one hue (206°) as surface steps, edges,
 * text and a few state colours. Every colour on screen comes from here; nothing else parses one.
 */
object Tone {
    const val bg = 0xFF111113.toInt()
    /** Cards, grouped lists, the composer, sheets. */
    const val l1 = 0xFF171D21.toInt()
    /** Raised inside l1: the user bubble, options, pills, the pop menu, pressed rows. */
    const val l2 = 0xFF1D252A.toInt()
    /** The selected segment, secondary buttons, pressed inside l2. */
    const val l3 = 0xFF263036.toInt()
    /** Edges and separators: #BED7EB at 8 %. */
    const val hair = 0x14BED7EB
    /** The composer's, a sheet's top and the menu's edge: #BED7EB at 13 %. */
    const val hair2 = 0x21BED7EB
    const val text = 0xFFEDEDED.toInt()
    const val dim = 0xFF89959F.toInt()
    const val faint = 0xFF77828B.toInt()
    /** What a tap acts on or what is chosen (b300). */
    const val accent = 0xFF6AB1E7.toInt()
    const val b200 = 0xFFA3C3DC.toInt()
    const val b400 = 0xFF3C97DD.toInt()
    const val b500 = 0xFF257DC1.toInt()
    const val onAccent = 0xFF0F1418.toInt()
    /** accent at 13 %. */
    const val accentFill = 0x216AB1E7
    /** Needs you, and only that. */
    const val warn = 0xFFE1C08D.toInt()
    const val warnFill = 0x1AE1C08D
    const val warnEdge = 0x24E1C08D
    const val err = 0xFFF0736B.toInt()
    const val errFill = 0x1FF0736B
    const val ok = 0xFF74C991.toInt()
    const val spinClaude = 0xFFF59A55.toInt()
    const val spinCodex = 0xFFFFFFFF.toInt()
    /** Codex's mark, beside Claude's own orange. */
    const val codexMark = 0xFFC9CFD4.toInt()
    /** The sheet's grab bar. */
    const val grab = 0xFF3A4148.toInt()
    /** Inline code keeps its warm colour. */
    const val code = 0xFFE8C08A.toInt()
    /** The ground of a code block and a permission's command. */
    const val well = 0xFF0D0F11.toInt()
    /** The need-you card's edge: warn at 18 %. */
    const val warnCard = 0x2EE1C08D
    /** The composer's edge while the field has focus: accent at 45 %. */
    const val focus = 0x736AB1E7
    /** Pressed on l3 (a secondary button). */
    const val l3Pressed = 0xFF2E3A41.toInt()
    /** Pressed on warnFill (the need-you cue). */
    const val warnPressed = 0x29E1C08D
    /** The ring round a held item: accent at 50 %. */
    const val held = 0x806AB1E7.toInt()
    /** Pressed on errFill (a destructive button). */
    const val errPressed = 0x33F0736B
    /** A diff's added and removed lines: ok and err at 10 %. */
    const val okLine = 0x1A74C991
    const val errLine = 0x1AF0736B
    /** The skeleton's moving band. */
    const val shimmer = 0xFF1B2227.toInt()
    /** The switch's knob (spec §5): on, off. */
    const val knobOn = 0xFFF4F7FA.toInt()
    const val knobOff = 0xFFAEB7BF.toInt()
    /** Plan mode's colour, as the Mac's mode rungs. */
    const val plan = 0xFF5FB3A8.toInt()
    const val b600 = 0xFF1B6298.toInt()
    /** The Mac's tab-group palette (data, not chrome). */
    const val groupGrey = 0xFF9AA4AD.toInt()
    const val groupBlue = 0xFF6FA8DC.toInt()
    const val groupTeal = 0xFF5FB5AE.toInt()
    const val groupGreen = 0xFF7DBE8B.toInt()
    const val groupSand = 0xFFCDB173.toInt()
    const val groupOrange = 0xFFDE9467.toInt()
    const val groupRose = 0xFFDC7F92.toInt()
    const val groupViolet = 0xFFA390D8.toInt()
}

/** The type scale (spec §2): a role per use, so no screen sets its own size. Sizes follow the phone's font scale. */
enum class Type(val sp: Float, val lineSp: Float, val weight: Int, val mono: Boolean = false) {
    Display(24f, 30f, 600),
    Title(18f, 24f, 600),
    Headline(16f, 22f, 600),
    Body(15f, 22f, 400),
    BodyMedium(15f, 20f, 500),
    Callout(13f, 18f, 400),
    Label(12.5f, 16f, 500),
    Caption(12f, 16f, 400),
    Mono(13f, 19f, 400, mono = true),
}

/** Sets a role's size, line height and weight (Roboto, or Roboto Mono). */
fun TextView.type(role: Type) {
    textSize = role.sp
    lineHeight = (role.lineSp * resources.displayMetrics.scaledDensity).toInt()
    typeface = Typeface.create(if (role.mono) Typeface.MONOSPACE else Typeface.DEFAULT, role.weight, false)
    if (role == Type.Display) letterSpacing = -0.01f
}

/** The spacing grid and the radii (spec §3), in dp. */
object Space {
    const val margin = 16
    const val marginWide = 20
    const val column = 560
    const val rowMin = 60
}

object Radius {
    const val row = 14
    const val group = 16
    const val card = 18
    const val composer = 22
    const val sheet = 28
    const val menu = 16
    const val menuRow = 11
    const val tile = 28
}

/** Durations (spec §3 motion), already scaled by the phone's animator setting (0 stills everything). */
object Motion {
    val scale: Float get() = if (ValueAnimator.areAnimatorsEnabled()) 1f else 0f
    fun ms(base: Long): Long = (base * scale).toLong()
    const val press = 120L
    const val sheetIn = 220L
    const val sheetOut = 160L
}

/** A shape filled with [fill], edged with [edge] (1 dp), at [radius] dp. */
fun Context.shape(fill: Int, radius: Int, edge: Int? = null): GradientDrawable = GradientDrawable().apply {
    setColor(fill)
    cornerRadius = dp(radius).toFloat()
    if (edge != null) setStroke(maxOf(1, dp(1)), edge)
}

/**
 * Pressable, the spec's way: the pressed state is one surface step up ([pressedFill]) with an
 * accent ripple at 10 % clipped to the shape. [fill] null: no ground at rest (a quiet row).
 */
fun View.pressFill(fill: Int?, pressedFill: Int, radius: Int, edge: Int? = null) {
    val c = context
    val rest = c.shape(fill ?: 0, radius, edge)
    val pressed = c.shape(pressedFill, radius, edge)
    val states = android.graphics.drawable.StateListDrawable().apply {
        setEnterFadeDuration(Motion.ms(Motion.press).toInt())
        setExitFadeDuration(Motion.ms(Motion.press).toInt())
        addState(intArrayOf(android.R.attr.state_pressed), pressed)
        addState(intArrayOf(), rest)
    }
    background = RippleDrawable(ColorStateList.valueOf(0x1A6AB1E7), states, c.shape(0xFFFFFFFF.toInt(), radius))
    // Set on a view already on screen (a toggled option), the state list would fade in from nothing.
    background.jumpToCurrentState()
    isClickable = true
}

/**
 * The Mac tab's working spinner (spec §4): 8 spokes from radius 2.4 to 5.4 on a 16 box, 1.7 wide,
 * round ends, fading from 1.0 to 0.3 round the turn, a step every 100 ms (0.8 s a turn), tinted
 * [tint]. Still under "Remove animations". Reads "Working" to TalkBack.
 */
class Spinner(context: Context, var tint: Int) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND; style = Paint.Style.STROKE }
    private var step = 0
    private val tick = object : Runnable {
        override fun run() {
            step = (step + 1) % 8
            invalidate()
            if (isAttachedToWindow && Motion.scale > 0f) postDelayed(this, 100)
        }
    }

    init {
        contentDescription = "Working"
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (Motion.scale > 0f) postDelayed(tick, 100)
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val unit = minOf(width, height) / 16f
        val cx = width / 2f
        val cy = height / 2f
        paint.strokeWidth = 1.7f * unit
        for (i in 0 until 8) {
            // The newest spoke is brightest; each before it fades toward 0.3.
            val age = (step - i + 8) % 8
            paint.color = tint
            paint.alpha = ((1f - age * (0.7f / 7f)) * 255).toInt()
            val a = Math.toRadians(i * 45.0 - 90.0)
            val dx = Math.cos(a).toFloat()
            val dy = Math.sin(a).toFloat()
            canvas.drawLine(cx + dx * 2.4f * unit, cy + dy * 2.4f * unit, cx + dx * 5.4f * unit, cy + dy * 5.4f * unit, paint)
        }
    }
}

/** A section's label (spec §2/§3: Label, sentence case, 18 above its list and 8 below; 6 above the first). */
fun android.app.Activity.sectionLabel(text: String, first: Boolean = false): TextView = TextView(this).apply {
    this.text = text
    type(Type.Label)
    setTextColor(Tone.dim)
    setPadding(dp(4), dp(if (first) 6 else 18), dp(4), dp(8))
}

/**
 * A grouped list (spec §5): `l1`, radius 16, a hair edge, its rows separated by hairlines inset
 * [inset] dp (52 past an icon column, 16 without). Rows made earlier and kept (a [RowCache]) move in.
 */
fun android.app.Activity.grouped(rows: List<View>, inset: Int = 52): android.widget.LinearLayout = android.widget.LinearLayout(this).apply {
    orientation = android.widget.LinearLayout.VERTICAL
    background = shape(Tone.l1, Radius.group, Tone.hair)
    clipToOutline = true
    rows.forEachIndexed { i, row ->
        (row.parent as? android.view.ViewGroup)?.removeView(row)
        if (i > 0) addView(View(context).apply { setBackgroundColor(Tone.hair) },
            android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.MATCH_PARENT, 1).apply { marginStart = dp(inset) })
        addView(row, android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.MATCH_PARENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT))
    }
}

/**
 * One grouped row (spec §3/§5): at least 60 high, padding 12 × 16, an 18 icon in a 24 column with
 * a 14 gap, a title (Body medium) over a second line (Callout), then [end] and, when it opens
 * something, a faint chevron.
 */
fun android.app.Activity.groupRow(
    icon: Int?, title: String, second: String?, titleColor: Int = Tone.text, secondColor: Int = Tone.dim,
    iconTint: Int = Tone.dim, end: View? = null, chevron: Boolean = false, titleMark: Int? = null, go: (() -> Unit)? = null,
): android.widget.LinearLayout = android.widget.LinearLayout(this).apply {
    gravity = android.view.Gravity.CENTER_VERTICAL
    minimumHeight = dp(Space.rowMin)
    setPadding(dp(16), dp(12), dp(16), dp(12))
    if (icon != null) addView(android.widget.ImageView(context).apply {
        setImageResource(icon)
        imageTintList = ColorStateList.valueOf(iconTint)
    }, android.widget.LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginStart = dp(3); marginEnd = dp(3 + 14) })
    addView(android.widget.LinearLayout(context).apply {
        orientation = android.widget.LinearLayout.VERTICAL
        // A 6 point after the title in [titleMark]'s colour (a device holding a login also held elsewhere).
        val name = TextView(context).apply { text = title; type(Type.BodyMedium); setTextColor(titleColor) }
        if (titleMark == null) addView(name) else addView(android.widget.LinearLayout(context).apply {
            gravity = android.view.Gravity.CENTER_VERTICAL
            addView(name)
            addView(point(titleMark, 6), android.widget.LinearLayout.LayoutParams(dp(6), dp(6)).apply { marginStart = dp(8) })
        })
        if (second != null) addView(TextView(context).apply { text = second; type(Type.Callout); setTextColor(secondColor) })
    }, android.widget.LinearLayout.LayoutParams(0, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    // An end view keeps the size it was made with (a 7 dp point would otherwise take the row's width).
    if (end != null) {
        val own = end.layoutParams
        val w = own?.width ?: android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
        val h = own?.height ?: android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
        addView(end, android.widget.LinearLayout.LayoutParams(w, h).apply { marginStart = dp(12) })
    }
    if (chevron) addView(android.widget.ImageView(context).apply {
        setImageResource(dev.kore.phone.R.drawable.i_chevron)
        imageTintList = ColorStateList.valueOf(Tone.faint)
    }, android.widget.LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginStart = dp(8) })
    if (go != null) {
        setOnClickListener { go() }
        pressFill(null, Tone.l2, 0)
    }
}

/** A small round point (the connected dot, the need-you point). */
fun android.content.Context.point(color: Int, size: Int = 7): View = View(this).apply {
    background = shape(color, size)
    layoutParams = android.widget.LinearLayout.LayoutParams(dp(size), dp(size))
}

/**
 * A state's tile (spec §5): [size] square (`l1`, [radius], a hair2 edge) holding a [glyph]-dp icon,
 * tinted b200 unless [tint] is false (the Kore mark keeps its colours). [waiting]: a ring 8 outside
 * it breathes, from 0.25 at 97 % to 1 at 100 % over 2.4 s; still with animations off. The view is
 * [size] + 16 square.
 */
fun android.app.Activity.stateTile(icon: Int, waiting: Boolean, size: Int = 88, radius: Int = Radius.tile, glyph: Int = 32, tint: Boolean = true): View =
    android.widget.FrameLayout(this).apply {
        if (waiting) {
            val ring = View(context).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dp(radius + 8).toFloat()
                    setStroke((1.5f * resources.displayMetrics.density).toInt(), 0x596AB1E7)
                }
            }
            if (Motion.scale > 0f) {
                val breathe = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = 2400
                    repeatMode = ValueAnimator.REVERSE
                    repeatCount = ValueAnimator.INFINITE
                    addUpdateListener { a ->
                        val t = a.animatedValue as Float
                        ring.alpha = 0.25f + 0.75f * t
                        ring.scaleX = 0.97f + 0.03f * t
                        ring.scaleY = ring.scaleX
                    }
                }
                // It runs while the ring is on screen, and stops when it leaves.
                ring.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                    override fun onViewAttachedToWindow(v: View) = breathe.start()
                    override fun onViewDetachedFromWindow(v: View) = breathe.cancel()
                })
            }
            addView(ring, android.widget.FrameLayout.LayoutParams(dp(size + 16), dp(size + 16), android.view.Gravity.CENTER))
        }
        addView(android.widget.FrameLayout(context).apply {
            background = shape(Tone.l1, radius, Tone.hair2)
            addView(android.widget.ImageView(context).apply {
                setImageResource(icon)
                if (tint) imageTintList = ColorStateList.valueOf(Tone.b200)
            }, android.widget.FrameLayout.LayoutParams(dp(glyph), dp(glyph), android.view.Gravity.CENTER))
        }, android.widget.FrameLayout.LayoutParams(dp(size), dp(size), android.view.Gravity.CENTER))
    }

/**
 * An empty state (spec §5): centred, 40 side padding; an 88 tile (`l1`, radius 28, a hair2 edge)
 * holding a 32 [icon] in b200; [title] in Display 8 below; [line] in Callout dim, at most 250 wide;
 * at most one [button] (primary, at most 260 wide, 24 above). [waiting]: a ring 8 outside the tile
 * (accent at 35 %, 1.5) breathes from 0.25 at 97 % to 1 at 100 % over 2.4 s; still with animations off.
 */
fun android.app.Activity.emptyState(
    icon: Int, title: String, line: String, button: Pair<String, () -> Unit>? = null, waiting: Boolean = false,
): View = android.widget.LinearLayout(this).apply {
    orientation = android.widget.LinearLayout.VERTICAL
    gravity = android.view.Gravity.CENTER_HORIZONTAL
    setPadding(dp(40), dp(72), dp(40), dp(32))
    addView(stateTile(icon, waiting), android.widget.LinearLayout.LayoutParams(dp(104), dp(104)))
    addView(TextView(context).apply {
        text = title; type(Type.Display); setTextColor(Tone.text); gravity = android.view.Gravity.CENTER
    }, android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
    addView(TextView(context).apply {
        text = line; type(Type.Callout); setTextColor(Tone.dim); gravity = android.view.Gravity.CENTER
        maxWidth = dp(250)
    }, android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
    if (button != null) addView(TextView(context).apply {
        text = button.first
        type(Type.Body)
        typeface = Typeface.create(Typeface.DEFAULT, 600, false)
        setTextColor(Tone.onAccent)
        gravity = android.view.Gravity.CENTER
        minHeight = dp(46)
        setPadding(dp(24), 0, dp(24), 0)
        maxWidth = dp(260)
        setOnClickListener { button.second() }
        pressFill(Tone.accent, Tone.b400, Radius.row)
    }, android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(24) })
}

/** A button's role (spec §5): primary, secondary, destructive or quiet. */
enum class Btn { Primary, Secondary, Destructive, Quiet }

/** A spec button: 46 high, radius 14, Body at 600, in its role's ground and ink. */
fun Context.button(text: String, role: Btn, go: () -> Unit): TextView = TextView(this).apply {
    this.text = text
    type(Type.Body)
    typeface = Typeface.create(Typeface.DEFAULT, 600, false)
    gravity = android.view.Gravity.CENTER
    minHeight = dp(46)
    setPadding(dp(16), 0, dp(16), 0)
    contentDescription = text
    setOnClickListener { go() }
    when (role) {
        Btn.Primary -> { setTextColor(Tone.onAccent); pressFill(Tone.accent, Tone.b400, Radius.row) }
        Btn.Secondary -> { setTextColor(Tone.text); pressFill(Tone.l3, Tone.l3Pressed, Radius.row) }
        Btn.Destructive -> { setTextColor(Tone.err); pressFill(Tone.errFill, Tone.errPressed, Radius.row) }
        Btn.Quiet -> { setTextColor(Tone.dim); pressFill(null, Tone.l2, Radius.row) }
    }
}

/** A shape with its own radius per corner (dp, clockwise from top-left): the user bubble's 18 18 6 18. */
fun Context.corners(fill: Int, tl: Int, tr: Int, br: Int, bl: Int, edge: Int? = null): GradientDrawable = GradientDrawable().apply {
    setColor(fill)
    val r = floatArrayOf(dp(tl).toFloat(), dp(tl).toFloat(), dp(tr).toFloat(), dp(tr).toFloat(), dp(br).toFloat(), dp(br).toFloat(), dp(bl).toFloat(), dp(bl).toFloat())
    cornerRadii = r
    if (edge != null) setStroke(maxOf(1, dp(1)), edge)
}

/**
 * The composer's ground (spec §3/§5): `l1`, radius 22, a hair2 edge (accent at 45 % while the
 * field has focus), and the lift: a shadow 8 up, 24 soft, black at 25 %. The shadow draws
 * outside the bounds, so the composer's parents don't clip their children.
 */
class ComposerGround(private val density: Float) : android.graphics.drawable.Drawable() {
    var focused = false
        set(value) { if (field != value) { field = value; invalidateSelf() } }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Tone.l1; setShadowLayer(12f * density, 0f, -8f * density, 0x40000000) }
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = maxOf(1f, density) }
    private val rect = android.graphics.RectF()

    override fun draw(c: Canvas) {
        val r = Radius.composer * density
        val half = edge.strokeWidth / 2
        rect.set(bounds.left + half, bounds.top + half, bounds.right - half, bounds.bottom - half)
        c.drawRoundRect(rect, r, r, fill)
        edge.color = if (focused) Tone.focus else Tone.hair2
        c.drawRoundRect(rect, r, r, edge)
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(cf: android.graphics.ColorFilter?) = Unit
    @Deprecated("Drawable API") override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
}

/**
 * The composer bar's step-down (spec §5), measured: the first step whose mode pill and model
 * text fit the room left after Attach, Arsenal and Send (which never go). Pure: widths in px.
 */
object ComposerFit {
    enum class Step {
        /** The pill's label and "Opus 5.5 · high". */ Full,
        /** The pill's label and "Opus 5.5". */ ShortModel,
        /** The pill's label, no model text. */ NoModel,
        /** The pill shows only its dot. */ DotOnly,
    }

    fun step(room: Int, pill: Int, modelFull: Int, modelShort: Int): Step = when {
        pill + modelFull <= room -> Step.Full
        pill + modelShort <= room -> Step.ShortModel
        pill <= room -> Step.NoModel
        else -> Step.DotOnly
    }
}

/**
 * A loading row (spec §5): 64 high, `l1`, radius 14, with a lighter band (`shimmer`) moving across
 * it over 1.4 s. Still under "Remove animations"; the animation runs only while it's on screen.
 */
class SkeletonRow(context: Context) : View(context) {
    private val ground = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Tone.l1 }
    private val band = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = android.graphics.RectF()
    private val clip = android.graphics.Path()
    private var t = 0f
    private val run = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 1400
        repeatCount = ValueAnimator.INFINITE
        addUpdateListener { t = it.animatedValue as Float; invalidate() }
    }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (Motion.scale > 0f) run.start()
    }

    override fun onDetachedFromWindow() {
        run.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val r = Radius.row * resources.displayMetrics.density
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        canvas.drawRoundRect(rect, r, r, ground)
        if (Motion.scale == 0f) return
        clip.reset(); clip.addRoundRect(rect, r, r, android.graphics.Path.Direction.CW)
        canvas.save(); canvas.clipPath(clip)
        val w = width * 0.4f
        val x = -w + (width + w) * t
        band.shader = android.graphics.LinearGradient(x, 0f, x + w, 0f, intArrayOf(Tone.l1, Tone.shimmer, Tone.l1), null, android.graphics.Shader.TileMode.CLAMP)
        canvas.drawRect(x, 0f, x + w, height.toFloat(), band)
        canvas.restore()
    }
}

/** Five loading rows, 8 apart (spec §5 Loading). */
fun android.app.Activity.skeleton(rows: Int = 5): View = android.widget.LinearLayout(this).apply {
    orientation = android.widget.LinearLayout.VERTICAL
    contentDescription = "Loading"
    repeat(rows) { addView(SkeletonRow(context), android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.MATCH_PARENT, dp(64)).apply { if (it > 0) topMargin = dp(8) }) }
}

/** Holds one child at most [max] px wide, centred at the foot; the rest stays clear (the 560 column, spec §7). */
class MaxWidth(context: Context, private val max: Int) : android.widget.FrameLayout(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        getChildAt(0)?.let { child ->
            val lp = child.layoutParams as LayoutParams
            lp.gravity = android.view.Gravity.CENTER_HORIZONTAL or android.view.Gravity.BOTTOM
            lp.width = if (width > max) max else LayoutParams.MATCH_PARENT
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}
