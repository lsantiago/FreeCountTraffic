package com.freecount.traffic.ui

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.SystemClock
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import com.freecount.traffic.core.Summary
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.source.CameraSource
import com.freecount.traffic.source.SourceType
import com.freecount.traffic.source.FRAME_WIDTH
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

@kotlin.OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun AnalysisScreen(vm: AnalysisViewModel, source: SourceType, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val state by vm.engine.state.collectAsState()
    val zones by vm.zones.collectAsState()

    androidx.compose.runtime.LaunchedEffect(source) { vm.selectSource(source) }

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

    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = 24.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            TextButton(onClick = { if (vm.running) vm.stop(); onBack() }) { Text("‹ Back") }
            Text(
                when (source) {
                    SourceType.CAMERA -> "Live camera"
                    SourceType.VIDEO -> "Video file"
                    SourceType.RTSP -> "RTSP stream"
                },
                style = MaterialTheme.typography.titleMedium,
            )
        }

        // --- frame source specific content ---
        var rtspTexture by remember { mutableStateOf<TextureView?>(null) }
        var rtspActive by remember { mutableStateOf<String?>(null) }

        if (source == SourceType.CAMERA) CameraBinding(vm)
        if (source == SourceType.RTSP) rtspActive?.let { RtspLoop(vm, rtspTexture, it) }

        FrameView(
            frame = state.frame,
            tracks = state.tracks,
            zones = zones,
            selectedId = vm.selectedZoneId,
            onSelect = { vm.selectedZoneId = it },
            onRectChange = vm::setRect,
            background = {
                if (source == SourceType.RTSP && rtspActive != null) {
                    RtspPlayerView(rtspActive!!, onTexture = { rtspTexture = it }, onError = { vm.message = it })
                }
            },
        )

        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!vm.modelReady) Text("Loading detection model…", style = MaterialTheme.typography.bodySmall)
            vm.message?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            Text(
                "Drag a zone to move it, drag its corner dot to resize. A vehicle is counted when it crosses the zone.",
                style = MaterialTheme.typography.bodySmall,
            )

            // --- source controls ---
            when (source) {
                SourceType.VIDEO -> {
                    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
                        if (uri != null) vm.loadVideo(uri)
                    }
                    OutlinedButton(onClick = { picker.launch("video/*") }, enabled = !vm.running) {
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
                    Button(
                        onClick = { rtspActive = vm.rtspUrl.trim().takeIf { it.startsWith("rtsp://") } ?: run { vm.message = "URL must start with rtsp://"; null } },
                        enabled = !vm.running,
                    ) { Text(if (rtspActive == null) "Connect" else "Reconnect") }
                }
                SourceType.CAMERA -> {}
            }

            val canStart = vm.modelReady && when (source) {
                SourceType.CAMERA -> true
                SourceType.VIDEO -> vm.videoUri != null
                SourceType.RTSP -> rtspActive != null
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                if (!vm.running) {
                    Button(onClick = { vm.start() }, enabled = canStart) { Text("Start counting") }
                } else {
                    Button(onClick = { vm.stop() }) { Text("Stop & save") }
                }
                if (vm.running && state.fps > 0f) Text(String.format("%.1f fps", state.fps))
            }

            // --- zones ---
            Text("Zones", style = MaterialTheme.typography.titleSmall)
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                zones.forEach { z ->
                    FilterChip(selected = z.id == vm.selectedZoneId, onClick = { vm.selectedZoneId = z.id }, label = { Text(z.name) })
                }
                OutlinedButton(onClick = { vm.addZone() }) { Text("+ Zone") }
            }
            zones.firstOrNull { it.id == vm.selectedZoneId }?.let { z ->
                var lengthText by remember(z.id) { mutableStateOf(z.lengthMeters?.let { l -> l.toString().removeSuffix(".0") } ?: "") }
                OutlinedTextField(
                    value = z.name, onValueChange = { vm.rename(z.id, it) },
                    label = { Text("Zone name") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = lengthText,
                    onValueChange = { t ->
                        lengthText = t
                        vm.setLength(z.id, t.replace(',', '.').toFloatOrNull()?.takeIf { it > 0f })
                    },
                    label = { Text("Zone length in meters (enables speed)") },
                    supportingText = { Text("Real distance covered by the zone's long side.") },
                    singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
                if (zones.size > 1) TextButton(onClick = { vm.deleteZone(z.id) }) { Text("Delete ${z.name}") }
            }

            // --- what to count ---
            Text("Count", style = MaterialTheme.typography.titleSmall)
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                VehicleClass.entries.forEach { c ->
                    FilterChip(selected = c in vm.enabledClasses, onClick = { vm.toggleClass(c) }, label = { Text(c.label) })
                }
            }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Switch(checked = vm.soundOn, onCheckedChange = { vm.soundOn = it })
                Text("Beep when a vehicle is counted")
            }

            // --- live results ---
            Text("Results", style = MaterialTheme.typography.titleSmall)
            Text("Total: ${state.events.size}")
            Summary.of(state.events, zones).forEach { Text(Summary.line(it)) }
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
            withContext(Dispatchers.Default) { vm.engine.process(bmp, t, counting) }
        }
    }
}
