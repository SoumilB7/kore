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
