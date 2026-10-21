package com.freecount.traffic.ui

import android.graphics.Bitmap
import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.Track
import com.freecount.traffic.core.Zone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

private fun rot(x: Float, y: Float, a: Float) = Offset(x * cos(a) - y * sin(a), x * sin(a) + y * cos(a))

/** A box (counting box or study area) in view pixels: centre, half sizes and clockwise rotation. */
private data class ViewBox(val c: Offset, val hw: Float, val hh: Float, val angle: Float) {
    /** View point of a point given in the box's own frame. */
    fun world(lx: Float, ly: Float) = c + rot(lx, ly, angle)

    /** A view point in the box's own frame. */
    fun local(p: Offset) = rot(p.x - c.x, p.y - c.y, -angle)

    fun contains(p: Offset): Boolean = local(p).let { abs(it.x) <= hw && abs(it.y) <= hh }

    /** The four corners with their sign in the box frame (top-left = -1, -1). */
    val corners: List<Triple<Float, Float, Offset>>
        get() = listOf(-1f to -1f, 1f to -1f, 1f to 1f, -1f to 1f).map { (sx, sy) -> Triple(sx, sy, world(sx * hw, sy * hh)) }

    /** The rotation handle sits above the middle of the top edge. */
    fun rotateHandle(gap: Float) = world(0f, -hh - gap)
}

private sealed interface Mode {
    data object Move : Mode
    data class Corner(val sx: Float, val sy: Float) : Mode
    data object Rotate : Mode
    data object Pan : Mode
}

/** What a touch grabbed. [zoneId] null = the study area. */
private class Grab(val mode: Mode, val zoneId: Int?, val start: ViewBox, val startPan: Offset)

private val ZOOM_STEPS = listOf(1f, 1.5f, 2f, 3f)

/**
 * Frame + live boxes + editable counting boxes, with zoom/pan and an optional study area.
 * Zone coordinates are normalized to the frame; everything is drawn and edited in view pixels.
 * The picture always fits inside the space given by [modifier] (vertical videos included).
 */
@Composable
fun FrameView(
    frame: Bitmap?,
    tracks: List<Track>,
    zones: List<Zone>,
    selectedId: Int?,
    onSelect: (Int) -> Unit,
    onZoneChange: (Int, RectN, Float) -> Unit,
    modifier: Modifier = Modifier,
    counts: Map<Int, Int> = emptyMap(),
    studyArea: RectN? = null,
    onStudyAreaChange: (RectN?) -> Unit = {},
    background: @Composable () -> Unit = {},
) {
    val aspect = frame?.let { it.width / it.height.toFloat() } ?: (16f / 9f)
    val image = remember(frame) { frame?.asImageBitmap() }
    val countsNow by rememberUpdatedState(counts)
    val zonesNow by rememberUpdatedState(zones)
    val selectedNow by rememberUpdatedState(selectedId)
    val tracksNow by rememberUpdatedState(tracks)
    val areaNow by rememberUpdatedState(studyArea)
    val onZoneChangeNow by rememberUpdatedState(onZoneChange)
    val onAreaNow by rememberUpdatedState(onStudyAreaChange)
    val onSelectNow by rememberUpdatedState(onSelect)

    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var editingArea by remember { mutableStateOf(false) }
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current.density
    val handleRadius = 24f * density
    val minSide = 18f * density
    val rotateGap = 28f * density

    BoxWithConstraints(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        Box(Modifier.aspectRatio(aspect).clipToBounds().onSizeChanged { viewSize = it }) {
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    scaleX = zoom
                    scaleY = zoom
                    translationX = pan.x
                    translationY = pan.y
                },
            ) {
                background()
                if (image != null) {
                    Image(image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                }
            }

            Canvas(
                Modifier
                    .fillMaxSize()
                    .pointerInput(viewSize) {
                        val w = size.width.toFloat()
                        val h = size.height.toFloat()

                        fun clampPan(p: Offset) = Offset(p.x.coerceIn(w - w * zoom, 0f), p.y.coerceIn(h - h * zoom, 0f))
                        fun setZoom(z: Float, anchor: Offset) {
                            val next = z.coerceIn(1f, 4f)
                            val q = (anchor - pan) / zoom
                            zoom = next
                            pan = clampPan(anchor - q * next)
                        }
                        fun box(r: RectN, angle: Float): ViewBox {
                            val sx = w * zoom
                            val sy = h * zoom
                            return ViewBox(Offset(r.cx * sx + pan.x, r.cy * sy + pan.y), r.width * sx / 2f, r.height * sy / 2f, angle)
                        }
                        fun rectN(b: ViewBox): RectN {
                            val sx = w * zoom
                            val sy = h * zoom
                            val cx = (b.c.x - pan.x) / sx
                            val cy = (b.c.y - pan.y) / sy
                            val hw = b.hw / sx
                            val hh = b.hh / sy
                            return RectN(cx - hw, cy - hh, cx + hw, cy + hh)
                        }
                        fun near(a: Offset, b: Offset) = hypot(a.x - b.x, a.y - b.y) <= handleRadius

                        // handles of the selected box first, then any box (selected first), otherwise the picture (pan)
                        fun grab(p: Offset): Grab? {
                            val panGrab = if (zoom > 1f) Grab(Mode.Pan, null, ViewBox(Offset.Zero, 0f, 0f, 0f), pan) else null
                            if (editingArea) {
                                val area = areaNow ?: return null
                                val b = box(area, 0f)
                                b.corners.firstOrNull { near(it.third, p) }?.let { return Grab(Mode.Corner(it.first, it.second), null, b, pan) }
                                if (b.contains(p)) return Grab(Mode.Move, null, b, pan)
                                return panGrab
                            }
                            zonesNow.firstOrNull { it.id == selectedNow }?.let { z ->
                                val b = box(z.rect, z.angle)
                                if (near(b.rotateHandle(rotateGap), p)) return Grab(Mode.Rotate, z.id, b, pan)
                                b.corners.firstOrNull { near(it.third, p) }?.let { return Grab(Mode.Corner(it.first, it.second), z.id, b, pan) }
                            }
                            val ordered = zonesNow.sortedByDescending { if (it.id == selectedNow) 1 else 0 }
                            ordered.firstOrNull { box(it.rect, it.angle).contains(p) }?.let { z ->
                                onSelectNow(z.id)
                                return Grab(Mode.Move, z.id, box(z.rect, z.angle), pan)
                            }
                            return panGrab
                        }

                        fun apply(g: Grab, start: Offset, p: Offset) {
                            val s = g.start
                            val b = when (val m = g.mode) {
                                Mode.Pan -> {
                                    pan = clampPan(g.startPan + (p - start))
                                    return
                                }
                                Mode.Move -> {
                                    val c = s.c + (p - start)
                                    // keep the centre on the picture
                                    s.copy(c = Offset(c.x.coerceIn(pan.x, pan.x + w * zoom), c.y.coerceIn(pan.y, pan.y + h * zoom)))
                                }
                                is Mode.Corner -> {
                                    // the opposite corner stays where it is
                                    val fixed = s.world(-m.sx * s.hw, -m.sy * s.hh)
                                    val d = rot(p.x - fixed.x, p.y - fixed.y, -s.angle)
                                    val bw = (d.x * m.sx).coerceAtLeast(minSide)
                                    val bh = (d.y * m.sy).coerceAtLeast(minSide)
                                    s.copy(c = fixed + rot(m.sx * bw / 2f, m.sy * bh / 2f, s.angle), hw = bw / 2f, hh = bh / 2f)
                                }
                                Mode.Rotate -> {
                                    var a = atan2(p.y - s.c.y, p.x - s.c.x) + (PI / 2).toFloat()
                                    if (a > PI) a -= (2 * PI).toFloat()
                                    // snap to straight angles
                                    val quarter = (PI / 2).toFloat()
                                    val snapped = (a / quarter).roundToInt() * quarter
                                    if (abs(a - snapped) < 0.07f) a = snapped
                                    if (abs(a) < 0.001f) a = 0f
                                    s.copy(angle = a)
                                }
                            }
                            val id = g.zoneId
                            if (id != null) {
                                onZoneChangeNow(id, rectN(b), b.angle)
                            } else {
                                val r = rectN(b)
                                onAreaNow(RectN(r.left.coerceAtLeast(0f), r.top.coerceAtLeast(0f), r.right.coerceAtMost(1f), r.bottom.coerceAtMost(1f)))
                            }
                        }

                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            var g = grab(down.position)
                            var pinched = false
                            do {
                                val event = awaitPointerEvent()
                                val pressed = event.changes.count { it.pressed }
                                if (pressed >= 2) {
                                    // two fingers: zoom around their centre
                                    pinched = true
                                    g = null
                                    setZoom(zoom * event.calculateZoom(), event.calculateCentroid(useCurrent = true))
                                    event.changes.forEach { it.consume() }
                                } else if (!pinched && g != null) {
                                    val ch = event.changes.first()
                                    apply(g, down.position, ch.position)
                                    ch.consume()
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    },
            ) {
                drawOverlay(
                    tracksNow, zonesNow, countsNow, selectedNow, areaNow, editingArea, zoom, pan, rotateGap,
                )
            }

            // zoom and study-area controls
            Row(
                Modifier.align(Alignment.TopStart).padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50))
                    .padding(horizontal = 10.dp, vertical = 5.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ToolLabel("⊕ ${(zoom * 100).roundToInt()}%") {
                    val next = ZOOM_STEPS.firstOrNull { it > zoom + 0.01f } ?: 1f
                    // zoom around the centre of the picture
                    val w = viewSize.width.toFloat()
                    val h = viewSize.height.toFloat()
                    val q = (Offset(w / 2f, h / 2f) - pan) / zoom
                    zoom = next
                    pan = (Offset(w / 2f, h / 2f) - q * next).let { Offset(it.x.coerceIn(w - w * next, 0f), it.y.coerceIn(h - h * next, 0f)) }
                }
                ToolLabel(if (editingArea) "✓ Done" else "⛶ Study area") {
                    editingArea = !editingArea
                    if (editingArea && areaNow == null) onAreaNow(RectN(0.1f, 0.1f, 0.9f, 0.9f))
                }
                if (editingArea && studyArea != null) {
                    ToolLabel("Whole frame") {
                        onAreaNow(null)
                        editingArea = false
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolLabel(text: String, onClick: () -> Unit) {
    Text(
        text, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
        modifier = Modifier.clickable(onClick = onClick),
    )
}

private fun DrawScope.drawOverlay(
    tracks: List<Track>,
    zones: List<Zone>,
    counts: Map<Int, Int>,
    selectedId: Int?,
    studyArea: RectN?,
    editingArea: Boolean,
    zoom: Float,
    pan: Offset,
    rotateGap: Float,
) {
    val w = size.width
    val h = size.height
    fun v(x: Float, y: Float) = Offset(x * w * zoom + pan.x, y * h * zoom + pan.y)
    fun viewRect(r: RectN) = Rect(v(r.left, r.top), v(r.right, r.bottom))
    val text = Paint().apply {
        isAntiAlias = true
        color = android.graphics.Color.WHITE
    }
    val canvas = drawContext.canvas.nativeCanvas
    val pillColor = Color(0xBF1F1F1F)

    for (t in tracks) {
        val c = Palette.cls(t.cls)
        val r = viewRect(t.box)
        drawRoundRect(c, r.topLeft, r.size, CornerRadius(3f * density), style = Stroke(1.5f * density))
        // small class tag, like the reference app's "car" / "truck" labels
        text.textSize = 10f * density
        text.isFakeBoldText = false
        val tag = t.cls.label.lowercase()
        val tw = text.measureText(tag) + 8f * density
        val ty = r.top - 14f * density
        drawRoundRect(c.copy(alpha = 0.9f), Offset(r.left, ty), Size(tw, 13f * density), CornerRadius(3f * density))
        canvas.drawText(tag, r.left + 4f * density, ty + 10.5f * density, text)
    }

    // outside the study area is dimmed: vehicles there are not analysed
    if (studyArea != null) {
        val a = viewRect(studyArea)
        val shade = Path().apply {
            fillType = PathFillType.EvenOdd
            addRect(Rect(Offset.Zero, size))
            addRect(a)
        }
        drawPath(shade, Color.Black.copy(alpha = 0.5f))
        drawRect(
            Color.White, a.topLeft, a.size,
            style = Stroke((if (editingArea) 2f else 1f) * density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f * density, 4f * density))),
        )
    }

    for ((i, z) in zones.withIndex()) {
        val c = Palette.zone(i)
        val selected = z.id == selectedId && !editingArea
        val r = viewRect(z.rect)
        val center = r.center
        val hw = r.width / 2f
        val hh = r.height / 2f
        withTransform({
            translate(center.x, center.y)
            rotate(Math.toDegrees(z.angle.toDouble()).toFloat(), pivot = Offset.Zero)
        }) {
            val tl = Offset(-hw, -hh)
            val sz = Size(2 * hw, 2 * hh)
            drawRoundRect(c.copy(alpha = if (selected) 0.40f else 0.28f), tl, sz, CornerRadius(6f * density))
            drawRoundRect(c, tl, sz, CornerRadius(6f * density), style = Stroke((if (selected) 3f else 2f) * density))
            // name and direction on a dark pill so vehicle labels passing underneath never hide them
            val title = z.name + (z.direction?.let { "  ${it.arrow}" } ?: "")
            text.textSize = 12f * density
            text.isFakeBoldText = true
            val pw = text.measureText(title) + 8f * density
            drawRoundRect(pillColor, Offset(tl.x + 3f * density, tl.y + 3f * density), Size(pw, 17f * density), CornerRadius(4f * density))
            drawContext.canvas.nativeCanvas.drawText(title, tl.x + 7f * density, tl.y + 15.5f * density, text)
        }

        // big count badge in the middle of the box, always upright (measured, so long counts fit)
        val count = (counts[z.id] ?: 0).toString()
        text.textSize = 16f * density
        text.isFakeBoldText = true
        val bw = text.measureText(count) + 16f * density
        val bh = 26f * density
        drawRoundRect(pillColor, Offset(center.x - bw / 2f, center.y - bh / 2f), Size(bw, bh), CornerRadius(8f * density))
        canvas.drawText(count, center.x - bw / 2f + 8f * density, center.y + 6f * density, text)

        if (selected) {
            val b = ViewBox(center, hw, hh, z.angle)
            b.corners.forEach { dot(it.third, c) }
            val top = b.world(0f, -hh)
            val handle = b.rotateHandle(rotateGap)
            drawLine(Color.White, top, handle, 1.5f * density)
            drawCircle(Color.White, 12f * density, handle)
            text.color = android.graphics.Color.BLACK
            text.textSize = 15f * density
            val g = "↻"
            canvas.drawText(g, handle.x - text.measureText(g) / 2f, handle.y + 5.5f * density, text)
            text.color = android.graphics.Color.WHITE
        }
    }

    if (editingArea && studyArea != null) {
        val a = viewRect(studyArea)
        listOf(a.topLeft, a.topRight, a.bottomRight, a.bottomLeft).forEach { dot(it, Color.White) }
    }
}

private fun DrawScope.dot(p: Offset, color: Color) {
    drawCircle(Color.White, 10f * density, p)
    drawCircle(color, 7f * density, p)
}
