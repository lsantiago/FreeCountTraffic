package com.freecount.traffic.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.data.Exporter
import com.freecount.traffic.data.SessionEntity
import com.freecount.traffic.data.ZoneJson
import com.freecount.traffic.source.SourceType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date
import java.util.Locale

@Composable
private fun TopBar(title: String, onBack: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) { Text("‹ Back", style = MaterialTheme.typography.titleSmall) }
        Text(title, Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.width(72.dp))
    }
}

@Composable
private fun SourceCard(title: String, subtitle: String, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(18.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
    }
}

@Composable
fun HomeScreen(onSource: (SourceType) -> Unit, onHistory: () -> Unit) {
    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Free Count Traffic", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Count vehicles and estimate their speed with on-device AI. Draw boxes on the image and press start. " +
                "Nothing is uploaded and videos are never stored: only counts and small images of the counted vehicles for validation.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(8.dp))
        // The visible titles are the plain source names; the subtitles explain each one.
        Button(onClick = { onSource(SourceType.CAMERA) }, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) { Text("Camera") }
        Text("Use the back camera of this phone, mounted still on a tripod or window.", style = MaterialTheme.typography.bodySmall)
        Button(onClick = { onSource(SourceType.VIDEO) }, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) { Text("Video file") }
        Text("Analyse a recorded video. Speed uses exact video timestamps.", style = MaterialTheme.typography.bodySmall)
        Button(onClick = { onSource(SourceType.RTSP) }, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) { Text("RTSP stream") }
        Text("Connect an IP camera or drone (Reolink, Hikvision, Axis, DJI…).", style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onHistory, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) { Text("History") }
    }
}

@Composable
fun HistoryScreen(vm: AnalysisViewModel, onBack: () -> Unit, onOpen: (Long) -> Unit) {
    val sessions by vm.sessions.collectAsState(initial = emptyList())
    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        TopBar("History", onBack)
        if (sessions.isEmpty()) {
            Text("No sessions yet.", modifier = Modifier.padding(20.dp))
        }
        LazyColumn(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(sessions, key = { it.id }) { s ->
                Column(
                    Modifier.fillMaxWidth()
                        .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(14.dp))
                        .clickable { onOpen(s.id) }
                        .padding(14.dp),
                ) {
                    Text(s.name, style = MaterialTheme.typography.titleSmall)
                    Text(
                        "${s.source.lowercase()} · ${s.durationMs / 1000} s · " +
                            DateFormat.getDateTimeInstance().format(Date(s.startedAt)),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@Composable
fun SessionDetailScreen(
    vm: AnalysisViewModel,
    id: Long,
    onBack: () -> Unit,
    onGraph: () -> Unit = {},
    onValidate: (Int) -> Unit = {},
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<Pair<SessionEntity, List<CountEvent>>?>(null) }
    var version by remember { mutableStateOf(0) }
    LaunchedEffect(id, version) { data = vm.sessionWithEvents(id) }
    var renaming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }

    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = 28.dp),
    ) {
        TopBar("Tracking Results", onBack)
        val (session, events) = data ?: run {
            Text("Loading…", Modifier.padding(20.dp))
            return@Column
        }
        val zones = ZoneJson.decode(session.zonesJson)
        if (renaming) {
            AlertDialog(
                onDismissRequest = { renaming = false },
                title = { Text("Rename") },
                text = { OutlinedTextField(value = newName, onValueChange = { newName = it }, singleLine = true) },
                confirmButton = {
                    TextButton(onClick = { renaming = false; scope.launch { vm.renameSession(id, newName); version++ } }) { Text("Save") }
                },
                dismissButton = { TextButton(onClick = { renaming = false }) { Text("Cancel") } },
            )
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                session.name + "  ✎",
                Modifier.fillMaxWidth().clickable { newName = session.name; renaming = true },
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.titleLarge,
            )
            Button(onClick = onGraph, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) { Text("Show Graph") }
            ResultsPanel(events, zones, onValidate = onValidate)

            val meta = buildString {
                append(DateFormat.getDateTimeInstance().format(Date(session.startedAt)))
                append("\nDuration: ${com.freecount.traffic.core.CsvExporter.clock(session.durationMs)} · ${session.source.lowercase()}")
                if (session.latitude != null && session.longitude != null) {
                    append(String.format(Locale.US, "\nLocation: %.5f, %.5f", session.latitude, session.longitude))
                }
            }
            Text(meta, Modifier.fillMaxWidth().padding(vertical = 8.dp), textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(shape = RoundedCornerShape(12.dp), onClick = {
                    scope.launch {
                        val files = withContext(Dispatchers.IO) { Exporter.csv(ctx, session, events) }
                        Exporter.share(ctx, files, "text/csv")
                    }
                }) { Text("Export CSV") }
                Button(shape = RoundedCornerShape(12.dp), onClick = {
                    scope.launch {
                        val f = withContext(Dispatchers.IO) { Exporter.pdf(ctx, session, events) }
                        Exporter.share(ctx, listOf(f), "application/pdf")
                    }
                }) { Text("Export PDF") }
            }
            Text("CSV export includes every vehicle and the 15-minute volume table.", style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = { vm.deleteSession(id); onBack() }) { Text("Delete session") }

            Text("Vehicles", style = MaterialTheme.typography.titleMedium)
            events.forEach {
                val speed = it.speedKmh?.let { s -> String.format(Locale.US, " · %.0f km/h", s) } ?: ""
                Text(
                    "${com.freecount.traffic.core.CsvExporter.clock(it.timeMs, session.clockStart)}  ${it.zoneName}  ${it.cls.label} ${it.direction}$speed",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Normal,
                )
            }
        }
    }
}
