package com.freecount.traffic.ui

import android.annotation.SuppressLint
import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.freecount.traffic.core.Heading
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone
import com.freecount.traffic.data.AppDb
import com.freecount.traffic.data.SessionEntity
import com.freecount.traffic.data.ThumbStore
import com.freecount.traffic.data.ZoneJson
import com.freecount.traffic.ml.AnalysisEngine
import com.freecount.traffic.ml.DetectionModel
import com.freecount.traffic.ml.InputSize
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
    private val prefs = app.getSharedPreferences("settings", android.content.Context.MODE_PRIVATE)
    val engine = AnalysisEngine(app)

    val sessions = dao.observeSessions()

    /** The last-used boxes are kept between launches, like the reference app. */
    private val _zones = MutableStateFlow(
        ZoneJson.decode(prefs.getString("zones", null) ?: "").ifEmpty { listOf(Zone(1, "Zone 1", RectN(0.2f, 0.4f, 0.8f, 0.6f), null)) },
    )
    val zones: StateFlow<List<Zone>> = _zones
    var selectedZoneId by mutableStateOf(_zones.value.firstOrNull()?.id)
    private var nextZoneId = (_zones.value.maxOfOrNull { it.id } ?: 0) + 1

    var modelReady by mutableStateOf(false)
    var running by mutableStateOf(false)
    var soundOn by mutableStateOf(prefs.getBoolean("soundOn", true))
        private set
    var confidence by mutableStateOf(prefs.getFloat("confidence", 0.30f))
        private set
    var saveImages by mutableStateOf(prefs.getBoolean("saveImages", true))
        private set
    var enabledClasses by mutableStateOf(engine.enabledClasses)
    var message by mutableStateOf<String?>(null)
    var progress by mutableStateOf<Float?>(null)
    var videoUri by mutableStateOf<Uri?>(null)
    var rtspUrl by mutableStateOf("")

    /** Name of the next session: video file name or a date; editable. */
    var sessionName by mutableStateOf("")
        private set
    private var nameEdited = false

    /** Most recent session saved from the analysis screen (its results open automatically). */
    var lastSessionId by mutableStateOf<Long?>(null)
        private set

    private var source = SourceType.CAMERA
    var startedAt = 0L
        private set
    private var clockStart: Long? = null
    private var latitude: Double? = null
    private var longitude: Double? = null
    private var job: Job? = null

    fun setSound(on: Boolean) {
        soundOn = on
        prefs.edit().putBoolean("soundOn", on).apply()
    }

    fun setConfidenceThreshold(value: Float) {
        confidence = value
        engine.confidence = value
        prefs.edit().putFloat("confidence", value).apply()
    }

    fun setSaveImagesOn(on: Boolean) {
        saveImages = on
        engine.saveImages = on
        prefs.edit().putBoolean("saveImages", on).apply()
    }

    fun editSessionName(name: String) {
        sessionName = name
        nameEdited = true
    }

    /** Part of the frame analysed (null = whole frame), stored as "l,t,r,b". */
    var studyArea by mutableStateOf(
        prefs.getString("studyArea", null)?.split(',')?.mapNotNull { it.toFloatOrNull() }
            ?.takeIf { it.size == 4 }?.let { RectN(it[0], it[1], it[2], it[3]) },
    )
        private set

    fun changeStudyArea(area: RectN?) {
        studyArea = area
        engine.studyArea = area
        prefs.edit().apply {
            if (area == null) remove("studyArea") else putString("studyArea", "${area.left},${area.top},${area.right},${area.bottom}")
        }.apply()
    }

    init {
        engine.studyArea = studyArea
        engine.zones = _zones.value
        engine.confidence = confidence
        engine.saveImages = saveImages
        loadDetector()
    }

    /** Settings: Balanced (YOLO11s) or Fastest (YOLO11n). */
    var detectionModel by mutableStateOf(
        runCatching { DetectionModel.valueOf(prefs.getString("detectionModel", "") ?: "") }.getOrDefault(DetectionModel.FASTEST),
    )
        private set

    fun chooseDetectionModel(model: DetectionModel) {
        if (running || model == detectionModel) return
        detectionModel = model
        prefs.edit().putString("detectionModel", model.name).apply()
        loadDetector()
    }

    /** Settings: detector input size (smaller = faster, misses distant vehicles). */
    var inputSize by mutableStateOf(
        runCatching { InputSize.valueOf(prefs.getString("inputSize", "") ?: "") }.getOrDefault(InputSize.MEDIUM),
    )
        private set

    fun chooseInputSize(size: InputSize) {
        if (running || size == inputSize) return
        inputSize = size
        prefs.edit().putString("inputSize", size.name).apply()
        loadDetector()
    }

    private fun loadDetector() {
        modelReady = false
        val model = runCatching { DetectionModel.valueOf(prefs.getString("detectionModel", "") ?: "") }.getOrDefault(DetectionModel.FASTEST)
        val size = runCatching { InputSize.valueOf(prefs.getString("inputSize", "") ?: "") }.getOrDefault(InputSize.MEDIUM)
        viewModelScope.launch(Dispatchers.Default) {
            try {
                engine.init(model, size)
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
        prefs.edit().putString("zones", ZoneJson.encode(next)).apply()
    }

    fun setDirection(id: Int, heading: Heading?) =
        updateZones { list -> list.map { if (it.id == id) it.copy(direction = heading) else it } }

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

    fun setRect(id: Int, rect: RectN, angle: Float = 0f) =
        updateZones { list -> list.map { if (it.id == id) it.copy(rect = rect, angle = angle) else it } }
    /** Box settings: exact rotation (clockwise radians, 0 = straight). */
    fun setAngle(id: Int, angle: Float) = updateZones { list -> list.map { if (it.id == id) it.copy(angle = angle) else it } }
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
        sessionName = ""
        nameEdited = false
        lastSessionId = null
    }

    fun loadVideo(uri: Uri) {
        videoUri = uri
        clockStart = null
        if (!nameEdited) sessionName = displayName(uri) ?: "Video"
        viewModelScope.launch(Dispatchers.Default) {
            clockStart = VideoSource.creationTime(getApplication(), uri)
            val frame = VideoSource.firstFrame(getApplication(), uri)
            if (frame != null) engine.showFrame(frame) else message = "Could not read that video."
        }
    }

    fun start() {
        if (running || !modelReady) return
        engine.reset()
        startedAt = System.currentTimeMillis()
        if (source != SourceType.VIDEO) {
            clockStart = startedAt
            if (!nameEdited) sessionName = "Session " + SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date(startedAt))
        }
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
        val result = engine.finish(aspect)
        val events = result.events
        val name = sessionName.trim().ifEmpty { "Session " + SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date(startedAt)) }
        val entity = SessionEntity(
            name = name, source = source.name, startedAt = startedAt,
            durationMs = if (source == SourceType.VIDEO) result.spanMs else System.currentTimeMillis() - startedAt,
            latitude = latitude, longitude = longitude,
            zonesJson = ZoneJson.encode(_zones.value),
            clockStart = clockStart,
        )
        viewModelScope.launch(Dispatchers.IO) {
            val id = dao.save(entity, events)
            ThumbStore.save(getApplication(), id, result.thumbnails)
            message = "Saved ${com.freecount.traffic.core.Summary.unique(events).size} vehicles to History."
            withContext(Dispatchers.Main) { lastSessionId = id }
        }
    }

    private fun displayName(uri: Uri): String? = runCatching {
        if (uri.scheme == "file") return@runCatching uri.lastPathSegment?.substringBeforeLast('.')
        getApplication<Application>().contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0)?.substringBeforeLast('.') else null }
    }.getOrNull()

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
            while (lastSessionId == null) kotlinx.coroutines.delay(200)
            val events = engine.state.value.events
            withContext(Dispatchers.IO) {
                java.io.File(dir, "autotest_result.csv").writeText(com.freecount.traffic.core.CsvExporter.build("autotest", events))
                val summary = com.freecount.traffic.core.Summary.of(events, _zones.value)
                    .joinToString("\n") { com.freecount.traffic.core.Summary.line(it) }
                val unique = com.freecount.traffic.core.Summary.unique(events).size
                val images = events.count { ThumbStore.file(getApplication(), lastSessionId ?: 0, it.trackId) != null }
                java.io.File(dir, "autotest_summary.txt").writeText(
                    "total=${events.size}\nunique=$unique\nimages=$images\n" +
                        "fps=${String.format(Locale.US, "%.2f", engine.state.value.fps)}\n$summary\n",
                )
                android.util.Log.i("AutoTest", "total=${events.size} unique=$unique images=$images")
                summary.lines().forEach { android.util.Log.i("AutoTest", it) }
                java.io.File(dir, "autotest_done").writeText("ok")
            }
            // UI tour for the CI screenshots: results (+1 s), graph (+6 s), validation (+13 s)
            for ((delayS, stage) in listOf(1 to 1, 5 to 2, 7 to 4)) {
                kotlinx.coroutines.delay(delayS * 1000L)
                autotestStage = stage
            }
        }
    }

    /** 1 = open results, 2 = show graph, 4 = validate the first box (CI only). */
    var autotestStage by mutableStateOf(0)
        private set

    // ---- history ----
    suspend fun sessionWithEvents(id: Long) = dao.session(id)?.let { it to dao.records(id).map { r -> r.toEvent() } }

    fun deleteSession(id: Long) = viewModelScope.launch(Dispatchers.IO) {
        dao.delete(id)
        ThumbStore.delete(getApplication(), id)
    }

    suspend fun renameSession(id: Long, name: String) {
        val clean = name.trim()
        if (clean.isNotEmpty()) withContext(Dispatchers.IO) { dao.rename(id, clean) }
    }

    suspend fun deleteEvent(id: Long, zoneId: Int, trackId: Int) = withContext(Dispatchers.IO) { dao.deleteRecord(id, zoneId, trackId) }

    suspend fun reclassify(id: Long, trackId: Int, cls: VehicleClass) = withContext(Dispatchers.IO) { dao.reclassify(id, trackId, cls.name) }

    fun thumbnail(id: Long, trackId: Int) = ThumbStore.file(getApplication(), id, trackId)

    override fun onCleared() {
        engine.close()
    }
}
