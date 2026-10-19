package com.freecount.traffic.ui

import android.annotation.SuppressLint
import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone
import com.freecount.traffic.data.AppDb
import com.freecount.traffic.data.SessionEntity
import com.freecount.traffic.data.ZoneJson
import com.freecount.traffic.ml.AnalysisEngine
import com.freecount.traffic.source.SourceType
import com.freecount.traffic.source.VideoSource
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class AnalysisViewModel(app: Application) : AndroidViewModel(app) {
    private val dao = AppDb.get(app).sessions()
    val engine = AnalysisEngine(app)

    val sessions = dao.observeSessions()

    private val _zones = MutableStateFlow(listOf(Zone(1, "Zone 1", RectN(0.2f, 0.4f, 0.8f, 0.6f), null)))
    val zones: StateFlow<List<Zone>> = _zones
    var selectedZoneId by mutableStateOf<Int?>(1)
    private var nextZoneId = 2

    var modelReady by mutableStateOf(false)
    var running by mutableStateOf(false)
    var soundOn by mutableStateOf(true)
    var enabledClasses by mutableStateOf(engine.enabledClasses)
    var message by mutableStateOf<String?>(null)
    var progress by mutableStateOf<Float?>(null)
    var videoUri by mutableStateOf<Uri?>(null)
    var rtspUrl by mutableStateOf("")

    private var source = SourceType.CAMERA
    private var startedAt = 0L
    private var latitude: Double? = null
    private var longitude: Double? = null
    private var job: Job? = null

    init {
        engine.zones = _zones.value
        viewModelScope.launch(Dispatchers.Default) {
            try {
                engine.init()
                modelReady = true
            } catch (t: Throwable) {
                message = "Could not load the detection model: ${t.message}"
            }
        }
    }

    // ---- zones ----
    fun updateZones(transform: (List<Zone>) -> List<Zone>) {
        val next = transform(_zones.value)
        _zones.value = next
        engine.zones = next
    }

    fun addZone() {
        val id = nextZoneId++
        val off = ((id - 1) % 4) * 0.05f
        updateZones { it + Zone(id, "Zone $id", RectN(0.15f + off, 0.3f + off, 0.55f + off, 0.5f + off), null) }
        selectedZoneId = id
    }

    fun deleteZone(id: Int) {
        updateZones { list -> list.filter { it.id != id } }
        selectedZoneId = _zones.value.firstOrNull()?.id
    }

    fun setRect(id: Int, rect: RectN) = updateZones { list -> list.map { if (it.id == id) it.copy(rect = rect) else it } }
    fun rename(id: Int, name: String) = updateZones { list -> list.map { if (it.id == id) it.copy(name = name) else it } }
    fun setLength(id: Int, meters: Float?) = updateZones { list -> list.map { if (it.id == id) it.copy(lengthMeters = meters) else it } }

    fun toggleClass(c: VehicleClass) {
        enabledClasses = if (c in enabledClasses) enabledClasses - c else enabledClasses + c
        engine.enabledClasses = enabledClasses
    }

    // ---- sessions ----
    fun selectSource(type: SourceType) {
        if (running) return
        source = type
        engine.reset()
        progress = null
        message = null
    }

    fun loadVideo(uri: Uri) {
        videoUri = uri
        viewModelScope.launch(Dispatchers.Default) {
            val frame = VideoSource.firstFrame(getApplication(), uri)
            if (frame != null) engine.showFrame(frame) else message = "Could not read that video."
        }
    }

    fun start() {
        if (running || !modelReady) return
        engine.reset()
        startedAt = System.currentTimeMillis()
        running = true
        message = null
        fetchLocation()
        if (source == SourceType.VIDEO) {
            val uri = videoUri ?: run { running = false; message = "Choose a video first."; return }
            job = viewModelScope.launch(Dispatchers.Default) {
                try {
                    VideoSource.run(getApplication(), uri, engine) { progress = it }
                } catch (t: kotlinx.coroutines.CancellationException) {
                    throw t
                } catch (t: Throwable) {
                    message = "Video error: ${t.message}"
                }
                withContext(Dispatchers.Main) { finishSession() }
            }
        }
    }

    fun stop() {
        viewModelScope.launch {
            job?.cancelAndJoin()
            job = null
            finishSession()
        }
    }

    private fun finishSession() {
        if (!running) return
        running = false
        val frame = engine.state.value.frame
        val aspect = frame?.let { it.width / it.height.toFloat() } ?: (16f / 9f)
        val events = engine.finish(aspect)
        val name = "Session " + SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date(startedAt))
        val entity = SessionEntity(
            name = name, source = source.name, startedAt = startedAt,
            durationMs = System.currentTimeMillis() - startedAt,
            latitude = latitude, longitude = longitude,
            zonesJson = ZoneJson.encode(_zones.value),
        )
        viewModelScope.launch(Dispatchers.IO) {
            dao.save(entity, events)
            message = "Saved ${events.size} vehicles to History."
        }
    }

    @SuppressLint("MissingPermission")
    private fun fetchLocation() {
        latitude = null
        longitude = null
        val ctx = getApplication<Application>()
        val granted = androidx.core.content.ContextCompat.checkSelfPermission(
            ctx, android.Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
            androidx.core.content.ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.ACCESS_FINE_LOCATION,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!granted) return
        runCatching {
            LocationServices.getFusedLocationProviderClient(ctx)
                .getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, null)
                .addOnSuccessListener { loc ->
                    if (loc != null) {
                        latitude = loc.latitude
                        longitude = loc.longitude
                    }
                }
        }
    }

    // ---- headless test run (used by CI: adb am start --es autotest_video ... --es autotest_zones ...) ----
    var autotestStarted = false

    /**
     * Runs one video through the pipeline and writes `autotest_result.csv`, `autotest_summary.txt` and
     * `autotest_done` into the app's private files dir. [fileName] is resolved inside that dir only.
     */
    fun runAutotest(fileName: String, testZones: List<Zone>) {
        if (autotestStarted) return
        autotestStarted = true
        val dir = getApplication<Application>().filesDir
        val file = java.io.File(dir, fileName)
        if (fileName.contains('/') || fileName.contains('\\') || !file.exists()) {
            android.util.Log.e("AutoTest", "video not found: $fileName")
            java.io.File(dir, "autotest_done").writeText("missing video")
            return
        }
        if (testZones.isNotEmpty()) {
            updateZones { testZones }
            selectedZoneId = testZones.first().id
            nextZoneId = maxOf(nextZoneId, testZones.maxOf { it.id } + 1)
        }
        viewModelScope.launch {
            while (!modelReady) kotlinx.coroutines.delay(200)
            selectSource(SourceType.VIDEO)
            loadVideo(Uri.fromFile(file))
            kotlinx.coroutines.delay(1000)
            start()
            while (running) kotlinx.coroutines.delay(500)
            val events = engine.state.value.events
            withContext(Dispatchers.IO) {
                java.io.File(dir, "autotest_result.csv").writeText(com.freecount.traffic.core.CsvExporter.build("autotest", events))
                val summary = com.freecount.traffic.core.Summary.of(events, _zones.value)
                    .joinToString("\n") { com.freecount.traffic.core.Summary.line(it) }
                java.io.File(dir, "autotest_summary.txt").writeText("total=${events.size}\n$summary\n")
                android.util.Log.i("AutoTest", "total=${events.size}")
                summary.lines().forEach { android.util.Log.i("AutoTest", it) }
                java.io.File(dir, "autotest_done").writeText("ok")
            }
        }
    }

    // ---- history ----
    suspend fun sessionWithEvents(id: Long) = dao.session(id)?.let { it to dao.records(id).map { r -> r.toEvent() } }
    fun deleteSession(id: Long) = viewModelScope.launch(Dispatchers.IO) { dao.delete(id) }

    override fun onCleared() {
        engine.close()
    }
}
