package com.freecount.traffic.ui

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.SystemClock
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.source.CameraSource
import com.freecount.traffic.source.FRAME_WIDTH
import com.freecount.traffic.source.SourceType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

private fun clock(ms: Long): String {
    val s = ms / 1000
    return String.format(Locale.US, "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

@kotlin.OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun AnalysisScreen(vm: AnalysisViewModel, source: SourceType, onBack: () -> Unit, onResults: (Long) -> Unit = {}, autotest: Boolean = false) {
    val ctx = LocalContext.current
    val state by vm.engine.state.collectAsState()
    val zones by vm.zones.collectAsState()

    LaunchedEffect(source) { vm.selectSource(source) }
    // like the reference app, the summary opens when a session ends (the CI autotest stays here)
    LaunchedEffect(vm.lastSessionId) { vm.lastSessionId?.let { if (!autotest) onResults(it) } }

    // Optional location permission (stored with the session).
    val locationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}
    LaunchedEffect(Unit) {
        val has = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!has) locationLauncher.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
    }

    // Beep on every new counted vehicle.
    val tone = remember { runCatching { ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80) }.getOrNull() }
    var lastCount by remember { mutableStateOf(0) }
    LaunchedEffect(state.events.size) {
        if (state.events.size > lastCount && vm.soundOn) tone?.startTone(ToneGenerator.TONE_PROP_BEEP, 80)
        lastCount = state.events.size
    }
    DisposableEffect(Unit) { onDispose { tone?.release() } }

    val elapsed by produceState(0L, vm.running) {
        while (vm.running) {
            value = System.currentTimeMillis() - vm.startedAt
            delay(500)
        }
    }

    val countsByZone = remember(state.events) { state.events.groupingBy { it.zoneId }.eachCount() }

    val aspect = state.frame?.let { it.width / it.height.toFloat() } ?: (16f / 9f)

    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        // --- top bar: ‹ Back | title ---
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { if (vm.running) vm.stop(); onBack() }) { Text("‹ Back", style = MaterialTheme.typography.titleSmall) }
            Text(
                when (source) {
                    SourceType.CAMERA -> "Live Camera"
                    SourceType.VIDEO -> "Video File"
                    SourceType.RTSP -> "RTSP Stream"
                },
                style = MaterialTheme.typography.titleMedium,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(72.dp))
        }

        var rtspTexture by remember { mutableStateOf<TextureView?>(null) }
        var rtspActive by remember { mutableStateOf<String?>(null) }

        if (source == SourceType.CAMERA) CameraBinding(vm)
        if (source == SourceType.RTSP) rtspActive?.let { RtspLoop(vm, rtspTexture, it) }

        val frameView: @Composable (Modifier, Boolean) -> Unit = { m, fillWidth ->
        FrameView(
            frame = state.frame,
            tracks = state.tracks,
            zones = zones,
            selectedId = vm.selectedZoneId,
            onSelect = { vm.selectedZoneId = it },
            onZoneChange = { id, r, a -> vm.setRect(id, r, a) },
            modifier = m,
            counts = countsByZone,
            studyArea = vm.studyArea,
            onStudyAreaChange = { vm.changeStudyArea(it) },
            fillWidth = fillWidth,
            background = {
                if (source == SourceType.RTSP && rtspActive != null) {
                    RtspPlayerView(rtspActive!!, onTexture = { rtspTexture = it }, onError = { vm.message = it })
                }
            },
        )
        }

        val controls: @Composable (Modifier) -> Unit = { m ->
        Column(
            m.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (!vm.modelReady) Text("Loading detection model…", style = MaterialTheme.typography.bodySmall)
            vm.message?.let { Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium) }

            // --- source controls ---
            when (source) {
                SourceType.VIDEO -> {
                    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
                        if (uri != null) vm.loadVideo(uri)
                    }
                    OutlinedButton(onClick = { picker.launch("video/*") }, enabled = !vm.running, modifier = Modifier.fillMaxWidth()) {
                        Text(if (vm.videoUri == null) "Choose video…" else "Choose another video…")
                    }
                    vm.progress?.let { if (vm.running) LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
                }
                SourceType.RTSP -> {
                    OutlinedTextField(
                        value = vm.rtspUrl,
                        onValueChange = { vm.rtspUrl = it },
                        label = { Text("rtsp://user:pass@host:554/stream") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedButton(
                        onClick = { rtspActive = vm.rtspUrl.trim().takeIf { it.startsWith("rtsp://") } ?: run { vm.message = "URL must start with rtsp://"; null } },
                        enabled = !vm.running,
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(if (rtspActive == null) "Connect" else "Reconnect") }
                }
                SourceType.CAMERA -> {}
            }

            OutlinedTextField(
                value = vm.sessionName,
                onValueChange = { vm.editSessionName(it) },
                label = { Text("Session name") },
                placeholder = { Text(if (source == SourceType.VIDEO) "Video file name" else "Date and time") },
                singleLine = true,
                enabled = !vm.running,
                modifier = Modifier.fillMaxWidth(),
            )

            val canStart = vm.modelReady && when (source) {
                SourceType.CAMERA -> true
                SourceType.VIDEO -> vm.videoUri != null
                SourceType.RTSP -> rtspActive != null
            }
            // Big orange action button (shows elapsed time while counting).
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (!vm.running) {
                    Button(onClick = { vm.start() }, enabled = canStart, shape = RoundedCornerShape(12.dp)) {
                        Text("Start counting", Modifier.padding(horizontal = 18.dp, vertical = 2.dp), fontWeight = FontWeight.SemiBold)
                    }
                } else {
                    Button(onClick = { vm.stop() }, shape = RoundedCornerShape(12.dp)) {
                        Text("■  Stop - ${clock(elapsed)}", Modifier.padding(horizontal = 18.dp, vertical = 2.dp), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            if (vm.running && state.fps > 0f) {
                Text(String.format(Locale.US, "%.1f fps", state.fps), Modifier.fillMaxWidth(), textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
            }

            // --- Boxes list (live) ---
            Spacer(Modifier.height(4.dp))
            Text("Boxes", style = MaterialTheme.typography.titleLarge)
            zones.forEachIndexed { i, z ->
                val selected = z.id == vm.selectedZoneId
                val byClass = state.events.filter { it.zoneId == z.id }.groupingBy { it.cls }.eachCount()
                // counts on the same line while they fit, otherwise on their own line (large counts, several classes)
                androidx.compose.foundation.layout.FlowRow(
                    Modifier.fillMaxWidth()
                        .background(if (selected) MaterialTheme.colorScheme.primaryContainer else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(10.dp))
                        .clickable { vm.selectedZoneId = z.id }
                        .padding(horizontal = 10.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Row(Modifier.align(Alignment.CenterVertically), verticalAlignment = Alignment.CenterVertically) {
                        Swatch(Palette.zone(i))
                        Spacer(Modifier.width(10.dp))
                        Text(
                            z.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 180.dp),
                        )
                        DirectionMenu(z.direction, enabled = !vm.running) { vm.setDirection(z.id, it) }
                    }
                    Box(Modifier.align(Alignment.CenterVertically).padding(start = 28.dp)) {
                        if (byClass.isEmpty()) Text("0", style = MaterialTheme.typography.bodyMedium) else ClassChips(byClass)
                    }
                }
            }
            OutlinedButton(onClick = { vm.addZone() }, shape = RoundedCornerShape(12.dp)) { Text("+ Add box") }
            Text(
                "Drag a box to move it, any corner dot to resize it and the round arrow above it to rotate it. A moving " +
                    "vehicle is counted when its centre enters the box. Tap the arrows next to a box to count only one " +
                    "direction. Pinch or tap the % button to zoom (drag the picture to look around; a vertical picture fills " +
                    "the width, drag it up or down to see the rest); Study area limits " +
                    "the analysis to part of the picture, which helps with distant vehicles.",
                style = MaterialTheme.typography.bodySmall,
            )

            // --- selected box settings ---
            zones.firstOrNull { it.id == vm.selectedZoneId }?.let { z ->
                var lengthText by remember(z.id) { mutableStateOf(z.lengthMeters?.let { l -> l.toString().removeSuffix(".0") } ?: "") }
                Text("Box settings", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
                OutlinedTextField(
                    value = z.name, onValueChange = { vm.rename(z.id, it) },
                    label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = lengthText,
                    onValueChange = { t ->
                        lengthText = t
                        vm.setLength(z.id, t.replace(',', '.').toFloatOrNull()?.takeIf { it > 0f })
                    },
                    label = { Text("Box length in meters (enables speed)") },
                    supportingText = { Text("Real distance covered by the box's long side.") },
                    singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                if (zones.size > 1) TextButton(onClick = { vm.deleteZone(z.id) }) { Text("Delete ${z.name}") }
            }

            // --- what to count ---
            Text("Count", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                VehicleClass.entries.forEach { c ->
                    FilterChip(selected = c in vm.enabledClasses, onClick = { vm.toggleClass(c) }, label = { Text(c.label) })
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Switch(checked = vm.soundOn, onCheckedChange = { vm.setSound(it) })
                Text("Beep when a vehicle is counted")
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Switch(checked = vm.saveImages, onCheckedChange = { vm.setSaveImagesOn(it) })
                Text("Save object images for Validate Detections (first ${com.freecount.traffic.ml.AnalysisEngine.MAX_THUMBNAILS})")
            }
            Text("Detection model (higher accuracy is slower)", style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                com.freecount.traffic.ml.DetectionModel.entries.forEach { m ->
                    FilterChip(
                        selected = vm.detectionModel == m,
                        onClick = { vm.chooseDetectionModel(m) },
                        enabled = !vm.running,
                        label = { Text(m.title) },
                    )
                }
            }
            Text("Detector image size (smaller is faster, misses distant vehicles)", style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                com.freecount.traffic.ml.InputSize.entries.forEach { s ->
                    FilterChip(
                        selected = vm.inputSize == s,
                        onClick = { vm.chooseInputSize(s) },
                        enabled = !vm.running,
                        label = { Text(s.title) },
                    )
                }
            }
            Text("Confidence threshold: ${(vm.confidence * 100).roundToInt()} %", style = MaterialTheme.typography.bodyMedium)
            Slider(
                value = vm.confidence,
                onValueChange = { vm.setConfidenceThreshold((it * 20).roundToInt() / 20f) },
                valueRange = 0.1f..0.9f,
            )
            Text("Lower finds more vehicles but also more false detections.", style = MaterialTheme.typography.bodySmall)

            // --- live results ---
            if (state.events.isNotEmpty()) {
                Text("Results", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 8.dp))
                ResultsPanel(state.events, zones)
            }
        }
        }

        // the picture never takes the whole screen (vertical videos, phone turned sideways): the controls always keep
        // their own scrollable space next to or below it
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
            val w = maxWidth
            val h = maxHeight
            if (w > h) {
                Row(Modifier.fillMaxSize()) {
                    frameView(Modifier.fillMaxHeight().width(w * 0.6f), false)
                    controls(Modifier.weight(1f).fillMaxHeight())
                }
            } else {
                Column(Modifier.fillMaxSize()) {
                    // a vertical picture fills the screen width (cropped top and bottom, drag to see the rest)
                    frameView(Modifier.fillMaxWidth().height(minOf(h * 0.48f, w / aspect)), true)
                    controls(Modifier.weight(1f).fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun CameraBinding(vm: AnalysisViewModel) {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) launcher.launch(Manifest.permission.CAMERA) }

    DisposableEffect(granted) {
        var cam: CameraSource? = null
        if (granted) {
            cam = CameraSource(ctx) { vm.running }.also { it.start(owner, vm.engine) { msg -> vm.message = "Camera: $msg" } }
        }
        onDispose { cam?.stop() }
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun RtspPlayerView(url: String, onTexture: (TextureView) -> Unit, onError: (String) -> Unit) {
    val ctx = LocalContext.current
    androidx.compose.runtime.key(url) {
        val player = remember {
            ExoPlayer.Builder(ctx).build().apply {
                setMediaSource(RtspMediaSource.Factory().setForceUseRtpTcp(true).createMediaSource(MediaItem.fromUri(url)))
                prepare()
                playWhenReady = true
                addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) = onError("RTSP error: ${error.errorCodeName}")
                })
            }
        }
        DisposableEffect(Unit) { onDispose { player.release() } }
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { c -> TextureView(c).also { player.setVideoTextureView(it); onTexture(it) } },
        )
    }
}

/** Grabs frames from the (hidden under the overlay) RTSP texture and feeds the engine. */
@Composable
private fun RtspLoop(vm: AnalysisViewModel, texture: TextureView?, url: String) {
    LaunchedEffect(texture, url) {
        val tv = texture ?: return@LaunchedEffect
        while (isActive) {
            delay(100)
            if (!tv.isAvailable || tv.width == 0) continue
            val h = (FRAME_WIDTH * tv.height / tv.width.toFloat()).toInt().coerceAtLeast(1)
            val bmp = tv.getBitmap(FRAME_WIDTH, h) ?: continue
            val counting = vm.running
            val t = SystemClock.elapsedRealtime()
            withContext(Dispatchers.Default) { vm.engine.submitLive(bmp, t, counting) }
        }
    }
}
