package com.freecount.traffic.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.Summary
import com.freecount.traffic.data.Exporter
import com.freecount.traffic.data.SessionEntity
import com.freecount.traffic.data.ZoneJson
import com.freecount.traffic.source.SourceType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

@Composable
fun HomeScreen(onSource: (SourceType) -> Unit, onHistory: () -> Unit) {
    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Free Count Traffic", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Count vehicles and estimate their speed with on-device AI. Draw counting boxes on the image " +
                "and press start. Nothing is uploaded: no video or photo is stored, only counts.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Button(onClick = { onSource(SourceType.CAMERA) }, modifier = Modifier.fillMaxWidth()) { Text("Camera") }
        Button(onClick = { onSource(SourceType.VIDEO) }, modifier = Modifier.fillMaxWidth()) { Text("Video file") }
        Button(onClick = { onSource(SourceType.RTSP) }, modifier = Modifier.fillMaxWidth()) { Text("RTSP stream") }
        OutlinedButton(onClick = onHistory, modifier = Modifier.fillMaxWidth()) { Text("History") }
    }
}

@Composable
fun HistoryScreen(vm: AnalysisViewModel, onBack: () -> Unit, onOpen: (Long) -> Unit) {
    val sessions by vm.sessions.collectAsState(initial = emptyList())
    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        Row(Modifier.padding(horizontal = 8.dp)) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            Text("History", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 12.dp))
        }
        if (sessions.isEmpty()) {
            Text("No sessions yet.", modifier = Modifier.padding(20.dp))
        }
        LazyColumn(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(sessions, key = { it.id }) { s ->
                Card(Modifier.fillMaxWidth().clickable { onOpen(s.id) }) {
                    Column(Modifier.padding(14.dp)) {
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
}

@Composable
fun SessionDetailScreen(vm: AnalysisViewModel, id: Long, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<Pair<SessionEntity, List<CountEvent>>?>(null) }
    LaunchedEffect(id) { data = vm.sessionWithEvents(id) }

    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = 24.dp),
    ) {
        TextButton(onClick = onBack, modifier = Modifier.padding(horizontal = 8.dp)) { Text("‹ Back") }
        val (session, events) = data ?: run {
            Text("Loading…", Modifier.padding(20.dp))
            return@Column
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(session.name, style = MaterialTheme.typography.titleLarge)
            Text("Source: ${session.source.lowercase()} · ${session.durationMs / 1000} s")
            if (session.latitude != null && session.longitude != null) {
                Text(String.format(java.util.Locale.US, "Location: %.5f, %.5f", session.latitude, session.longitude))
            }
            Text("Total: ${events.size}", style = MaterialTheme.typography.titleSmall)
            Summary.of(events, ZoneJson.decode(session.zonesJson)).forEach { Text(Summary.line(it)) }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    scope.launch {
                        val f = withContext(Dispatchers.IO) { Exporter.csv(ctx, session, events) }
                        Exporter.share(ctx, f, "text/csv")
                    }
                }) { Text("Export CSV") }
                Button(onClick = {
                    scope.launch {
                        val f = withContext(Dispatchers.IO) { Exporter.pdf(ctx, session, events) }
                        Exporter.share(ctx, f, "application/pdf")
                    }
                }) { Text("Export PDF") }
            }
            TextButton(onClick = { vm.deleteSession(id); onBack() }) { Text("Delete session") }

            Text("Vehicles", style = MaterialTheme.typography.titleSmall)
            events.forEach {
                val speed = it.speedKmh?.let { s -> String.format(java.util.Locale.US, " · %.0f km/h", s) } ?: ""
                Text(
                    String.format(java.util.Locale.US, "%.1fs  %s  %s %s%s", it.timeMs / 1000.0, it.zoneName, it.cls.label, it.direction, speed),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}
