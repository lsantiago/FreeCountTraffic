package com.freecount.traffic.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.CsvExporter
import com.freecount.traffic.core.IntervalRow
import com.freecount.traffic.core.Summary
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.data.SessionEntity
import com.freecount.traffic.data.ZoneJson
import com.freecount.traffic.ml.AnalysisEngine
import kotlinx.coroutines.launch
import java.util.Locale

@Composable
private fun ScreenBar(title: String, onBack: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) { Text("‹ Back", style = MaterialTheme.typography.titleSmall) }
        Text(title, Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.width(72.dp))
    }
}

/**
 * "Show Graph": vehicles per interval, stacked by class, for all boxes (unique vehicles) or one box,
 * plus the peak hour with its peak hour factor and the volume table.
 */
@Composable
fun GraphScreen(vm: AnalysisViewModel, id: Long, onBack: () -> Unit) {
    var data by remember { mutableStateOf<Pair<SessionEntity, List<CountEvent>>?>(null) }
    LaunchedEffect(id) { data = vm.sessionWithEvents(id) }
    var intervalMin by remember { mutableStateOf(15) }
    var zoneId by remember { mutableStateOf<Int?>(null) }

    Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = 28.dp)) {
        ScreenBar("Graph", onBack)
        val (session, events) = data ?: run {
            Text("Loading…", Modifier.padding(20.dp))
            return@Column
        }
        val zones = ZoneJson.decode(session.zonesJson)
        val label = { ms: Long -> CsvExporter.clock(ms, session.clockStart).take(5) }
        val rows = Summary.intervals(events, intervalMin * 60_000L, session.durationMs, zoneId)

        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(1, 5, 15, 60).forEach { m ->
                    FilterChip(selected = intervalMin == m, onClick = { intervalMin = m }, label = { Text(if (m == 60) "1 hour" else "$m min") })
                }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FilterChip(selected = zoneId == null, onClick = { zoneId = null }, label = { Text("All boxes (unique)") })
                zones.forEach { z -> FilterChip(selected = zoneId == z.id, onClick = { zoneId = z.id }, label = { Text(z.name) }) }
            }

            if (rows.all { it.total == 0 }) {
                Text("No vehicles counted.")
            } else {
                StackedBars(rows)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(label(rows.first().startMs), style = MaterialTheme.typography.bodySmall)
                    Text(label(rows.last().endMs), style = MaterialTheme.typography.bodySmall)
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    VehicleClass.entries.filter { c -> rows.any { (it.byClass[c] ?: 0) > 0 } }.forEach { c ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Swatch(Palette.cls(c), size = 10)
                            Text(" ${c.label}", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }

            val peak = Summary.peakHour(events, session.durationMs, zoneId)
            if (peak != null) {
                Column(
                    Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(12.dp)).padding(12.dp),
                ) {
                    Text("Peak hour", style = MaterialTheme.typography.titleSmall)
                    Text("${label(peak.startMs)} – ${label(peak.startMs + 3_600_000L)}: ${peak.volume} vehicles")
                    peak.phf?.let { Text(String.format(Locale.US, "Peak hour factor (PHF): %.2f", it)) }
                }
            } else {
                Text("Peak hour and PHF need at least one hour of counting.", style = MaterialTheme.typography.bodySmall)
            }

            Text("Volumes", style = MaterialTheme.typography.titleMedium)
            val classes = VehicleClass.entries.filter { c -> rows.any { (it.byClass[c] ?: 0) > 0 } }
            Row {
                Text("Start", Modifier.width(56.dp), style = MaterialTheme.typography.labelMedium)
                classes.forEach { Text(it.label, Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.labelMedium) }
                Text("Total", Modifier.width(48.dp), textAlign = TextAlign.End, style = MaterialTheme.typography.labelMedium)
            }
            rows.forEach { r ->
                Row {
                    Text(label(r.startMs), Modifier.width(56.dp), style = MaterialTheme.typography.bodySmall)
                    classes.forEach { c -> Text("${r.byClass[c] ?: 0}", Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall) }
                    Text("${r.total}", Modifier.width(48.dp), textAlign = TextAlign.End, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun StackedBars(rows: List<IntervalRow>) {
    val maxTotal = rows.maxOf { it.total }.coerceAtLeast(1)
    Canvas(Modifier.fillMaxWidth().height(220.dp)) {
        val slot = size.width / rows.size
        val barW = (slot * 0.75f).coerceAtLeast(1f)
        rows.forEachIndexed { i, r ->
            var top = size.height
            VehicleClass.entries.forEach { c ->
                val n = r.byClass[c] ?: 0
                if (n > 0) {
                    val h = size.height * n / maxTotal
                    top -= h
                    drawRect(Palette.cls(c), Offset(i * slot + (slot - barW) / 2, top), Size(barW, h))
                }
            }
        }
        drawLine(Color.Gray, Offset(0f, size.height), Offset(size.width, size.height), strokeWidth = 2f)
    }
}

/**
 * "Validate Detections": the image of every vehicle counted in one box with its class and confidence.
 * Wrong detections are removed with the red trash button; a wrong class is fixed by tapping the class.
 */
@Composable
fun ValidationScreen(vm: AnalysisViewModel, id: Long, zoneId: Int, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<Pair<SessionEntity, List<CountEvent>>?>(null) }
    var version by remember { mutableStateOf(0) }
    LaunchedEffect(id, version) { data = vm.sessionWithEvents(id) }
    var filter by remember { mutableStateOf<VehicleClass?>(null) }

    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        val zoneName = data?.first?.let { s -> ZoneJson.decode(s.zonesJson).firstOrNull { it.id == zoneId }?.name } ?: "Validate Detections"
        ScreenBar(zoneName, onBack)
        val events = data?.second?.filter { it.zoneId == zoneId } ?: emptyList()
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FilterChip(selected = filter == null, onClick = { filter = null }, label = { Text("All ${events.size}") })
            VehicleClass.entries.filter { c -> events.any { it.cls == c } }.forEach { c ->
                FilterChip(selected = filter == c, onClick = { filter = c }, label = { Text("${c.label} ${events.count { it.cls == c }}") })
            }
        }
        val shown = events.filter { filter == null || it.cls == filter }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(110.dp),
            modifier = Modifier.weight(1f).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(shown, key = { it.trackId }) { e ->
                Column {
                    Box {
                        val bmp = remember(e.trackId) {
                            vm.thumbnail(id, e.trackId)?.let { f -> BitmapFactory.decodeFile(f.path)?.asImageBitmap() }
                        }
                        if (bmp != null) {
                            Image(bmp, null, Modifier.fillMaxWidth().height(90.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
                        } else {
                            Box(Modifier.fillMaxWidth().height(90.dp).background(Color(0x22888888), RoundedCornerShape(8.dp)))
                        }
                        Box(
                            Modifier.align(Alignment.TopEnd).padding(4.dp).size(28.dp)
                                .background(Color(0xFFE53935), CircleShape)
                                .clickable { scope.launch { vm.deleteEvent(id, zoneId, e.trackId); version++ } },
                            contentAlignment = Alignment.Center,
                        ) { Text("✕", color = Color.White) }
                    }
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        TextButton(onClick = { menu = true }) {
                            Swatch(Palette.cls(e.cls), size = 10)
                            Text(" ${e.cls.label} ▾", style = MaterialTheme.typography.labelLarge)
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            VehicleClass.entries.forEach { c ->
                                DropdownMenuItem(
                                    text = { Text((if (c == e.cls) "✓ " else "") + c.label) },
                                    onClick = { menu = false; scope.launch { vm.reclassify(id, e.trackId, c); version++ } },
                                )
                            }
                        }
                    }
                    Text(
                        (e.score?.let { "${(it * 100).toInt()} %" } ?: "–") + " · " + e.direction,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        Text(
            "Images are kept for the first ${AnalysisEngine.MAX_THUMBNAILS} vehicles of a session, only on this device.",
            Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
