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
    counts: Map<Int, Int> = emptyMap(),
    background: @Composable () -> Unit = {},
) {
    val countsNow by rememberUpdatedState(counts)
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
            val cornerPx = 6f * density
            for (t in tracksNow) {
                val c = Palette.cls(t.cls)
                drawRoundRect(
                    c, Offset(t.box.left * w, t.box.top * h), Size(t.box.width * w, t.box.height * h),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(cornerPx), style = Stroke(1.5f * density),
                )
                // small class tag, like the reference app's "car" / "truck" labels
                text.textSize = 10f * density
                val tag = t.cls.label.lowercase()
                val tw = text.measureText(tag) + 8f * density
                val tx = t.box.left * w
                val ty = t.box.top * h - 14f * density
                drawRoundRect(c.copy(alpha = 0.9f), Offset(tx, ty), Size(tw, 13f * density), androidx.compose.ui.geometry.CornerRadius(3f * density))
                text.color = android.graphics.Color.WHITE
                drawContext.canvas.nativeCanvas.drawText(tag, tx + 4f * density, ty + 10.5f * density, text)
            }
            for ((i, z) in zonesNow.withIndex()) {
                val c = Palette.zone(i)
                val selected = z.id == selectedNow
                val tl = Offset(z.rect.left * w, z.rect.top * h)
                val sz = Size(z.rect.width * w, z.rect.height * h)
                drawRoundRect(c.copy(alpha = if (selected) 0.40f else 0.28f), tl, sz, androidx.compose.ui.geometry.CornerRadius(cornerPx))
                drawRoundRect(c, tl, sz, androidx.compose.ui.geometry.CornerRadius(cornerPx), style = Stroke((if (selected) 3f else 2f) * density))

                // big count badge in the middle of the box
                val count = (countsNow[z.id] ?: 0).toString()
                text.textSize = 16f * density
                text.isFakeBoldText = true
                val bw = text.measureText(count) + 16f * density
                val bh = 26f * density
                val bx = tl.x + (sz.width - bw) / 2f
                val by = tl.y + (sz.height - bh) / 2f
                drawRoundRect(Color(0xAA202020), Offset(bx, by), Size(bw, bh), androidx.compose.ui.geometry.CornerRadius(8f * density))
                text.color = android.graphics.Color.WHITE
                drawContext.canvas.nativeCanvas.drawText(count, bx + 8f * density, by + 19f * density, text)
                text.isFakeBoldText = false

                text.textSize = 12f * density
                text.color = android.graphics.Color.WHITE
                drawContext.canvas.nativeCanvas.drawText(z.name, tl.x + 6f * density, tl.y + 15f * density, text)
                if (selected) {
                    drawCircle(Color.White, 9f * density, Offset(z.rect.right * w, z.rect.bottom * h))
                    drawCircle(c, 7f * density, Offset(z.rect.right * w, z.rect.bottom * h))
                }
            }
        }
    }
}
