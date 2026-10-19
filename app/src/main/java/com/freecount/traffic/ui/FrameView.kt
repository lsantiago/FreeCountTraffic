package com.freecount.traffic.ui

import android.graphics.Bitmap
import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.Track
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone

private val ZONE_COLORS = listOf(
    Color(0xFFFFC107), Color(0xFF03A9F4), Color(0xFFE91E63), Color(0xFF8BC34A), Color(0xFFFF5722),
)

private fun classColor(c: VehicleClass) = when (c) {
    VehicleClass.CAR -> Color(0xFF4CAF50)
    VehicleClass.TRUCK -> Color(0xFFFF9800)
    VehicleClass.BUS -> Color(0xFFF44336)
    VehicleClass.MOTORCYCLE -> Color(0xFF9C27B0)
    VehicleClass.BICYCLE -> Color(0xFF00BCD4)
    VehicleClass.PERSON -> Color(0xFFFFFFFF)
}

private const val HANDLE = 0.07f
private const val MIN_SIZE = 0.04f

/** Frame + live boxes + editable counting zones. Coordinates are normalized to the frame. */
@Composable
fun FrameView(
    frame: Bitmap?,
    tracks: List<Track>,
    zones: List<Zone>,
    selectedId: Int?,
    onSelect: (Int) -> Unit,
    onRectChange: (Int, RectN) -> Unit,
    modifier: Modifier = Modifier,
    background: @Composable () -> Unit = {},
) {
    val aspect = frame?.let { it.width / it.height.toFloat() } ?: (16f / 9f)
    val image = remember(frame) { frame?.asImageBitmap() }
    val zonesNow by rememberUpdatedState(zones)
    val selectedNow by rememberUpdatedState(selectedId)
    val tracksNow by rememberUpdatedState(tracks)

    Box(modifier.fillMaxWidth().aspectRatio(aspect).background(Color.Black)) {
        background()
        if (image != null) {
            Image(image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
        }
        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures { o ->
                        val nx = o.x / size.width
                        val ny = o.y / size.height
                        zonesNow.lastOrNull { it.rect.contains(nx, ny) }?.let { onSelect(it.id) }
                    }
                }
                .pointerInput(Unit) {
                    var activeId = -1
                    var resizing = false
                    detectDragGestures(
                        onDragStart = { o ->
                            val nx = o.x / size.width
                            val ny = o.y / size.height
                            val ordered = zonesNow.sortedBy { if (it.id == selectedNow) 1 else 0 }.reversed()
                            val hit = ordered.firstOrNull { z ->
                                kotlin.math.abs(nx - z.rect.right) < HANDLE && kotlin.math.abs(ny - z.rect.bottom) < HANDLE
                            }?.also { resizing = true }
                                ?: ordered.firstOrNull { it.rect.contains(nx, ny) }?.also { resizing = false }
                            activeId = hit?.id ?: -1
                            hit?.let { onSelect(it.id) }
                        },
                        onDragEnd = { activeId = -1 },
                        onDragCancel = { activeId = -1 },
                    ) { change, drag ->
                        val z = zonesNow.firstOrNull { it.id == activeId } ?: return@detectDragGestures
                        change.consume()
                        val dx = drag.x / size.width
                        val dy = drag.y / size.height
                        val r = z.rect
                        val next = if (resizing) {
                            RectN(
                                r.left, r.top,
                                (r.right + dx).coerceIn(r.left + MIN_SIZE, 1f),
                                (r.bottom + dy).coerceIn(r.top + MIN_SIZE, 1f),
                            )
                        } else {
                            val mx = dx.coerceIn(-r.left, 1f - r.right)
                            val my = dy.coerceIn(-r.top, 1f - r.bottom)
                            r.shifted(mx, my)
                        }
                        onRectChange(z.id, next)
                    }
                },
        ) {
            val w = size.width
            val h = size.height
            val text = Paint().apply {
                isAntiAlias = true
                textSize = 13f * density
                setShadowLayer(3f, 0f, 0f, android.graphics.Color.BLACK)
            }
            for (t in tracksNow) {
                val c = classColor(t.cls)
                drawRect(c, Offset(t.box.left * w, t.box.top * h), Size(t.box.width * w, t.box.height * h), style = Stroke(2f * density))
                text.color = android.graphics.Color.WHITE
                drawContext.canvas.nativeCanvas.drawText("${t.cls.label} #${t.id}", t.box.left * w, t.box.top * h - 4f * density, text)
            }
            for ((i, z) in zonesNow.withIndex()) {
                val c = ZONE_COLORS[i % ZONE_COLORS.size]
                val tl = Offset(z.rect.left * w, z.rect.top * h)
                val sz = Size(z.rect.width * w, z.rect.height * h)
                drawRect(c.copy(alpha = if (z.id == selectedNow) 0.22f else 0.10f), tl, sz)
                drawRect(c, tl, sz, style = Stroke((if (z.id == selectedNow) 3f else 2f) * density))
                text.color = android.graphics.Color.WHITE
                drawContext.canvas.nativeCanvas.drawText(z.name, tl.x + 4f * density, tl.y + 15f * density, text)
                if (z.id == selectedNow) {
                    drawCircle(c, 7f * density, Offset(z.rect.right * w, z.rect.bottom * h))
                }
            }
        }
    }
}
