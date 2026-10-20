package com.freecount.traffic.ml

import android.content.Context
import android.graphics.Bitmap
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.SimpleTracker
import com.freecount.traffic.core.Track
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone
import com.freecount.traffic.core.ZoneCounter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

data class EngineState(
    val frame: Bitmap? = null,
    val tracks: List<Track> = emptyList(),
    val events: List<CountEvent> = emptyList(),
    val fps: Float = 0f,
)

/** What a finished session hands back: every event, the vehicle images (track id -> JPEG) and the analysed span. */
class EngineResult(val events: List<CountEvent>, val thumbnails: Map<Int, ByteArray>, val spanMs: Long)

/**
 * Detector -> tracker -> zone counter pipeline shared by every frame source.
 * [process] may be called from any single background thread; the other members are thread-safe.
 */
class AnalysisEngine(private val context: Context) {

    private val lock = Any()
    private var detector: VehicleDetector? = null
    private val tracker = SimpleTracker()
    private val counter = ZoneCounter()
    private var lastFrameNs = 0L
    private var fpsEma = 0f
    private var startMs: Long? = null
    private var lastMs = 0L
    private val thumbs = HashMap<Int, ByteArray>()

    @Volatile var zones: List<Zone> = emptyList()
    @Volatile var enabledClasses: Set<VehicleClass> = setOf(
        VehicleClass.CAR, VehicleClass.TRUCK, VehicleClass.BUS, VehicleClass.MOTORCYCLE,
    )
    @Volatile var confidence: Float = 0.30f
    @Volatile var saveImages: Boolean = true

    private val _state = MutableStateFlow(EngineState())
    val state: StateFlow<EngineState> = _state

    /** Loads (or swaps) the detection model. Call off the main thread. */
    fun init(model: DetectionModel = DetectionModel.FASTEST, inputSize: InputSize = InputSize.MEDIUM) {
        val fresh = VehicleDetector(context, model, inputSize) // heavy: build outside the lock
        synchronized(lock) {
            detector?.close()
            detector = fresh
        }
    }

    val isReady: Boolean get() = detector != null

    /** Show a frame without detecting (camera/video preview before the session starts). */
    fun showFrame(frame: Bitmap) {
        _state.value = _state.value.copy(frame = frame, tracks = emptyList())
    }

    private val liveWorker = Executors.newSingleThreadExecutor()
    private val liveBusy = AtomicBoolean(false)

    /**
     * Live sources (camera, RTSP): every frame is displayed at once (keeping the last boxes on top) and the detector
     * works on the latest frame in the background, so the picture stays fluid even when detection is slow.
     */
    fun submitLive(frame: Bitmap, rawMs: Long, counting: Boolean) {
        if (!counting || detector == null) {
            showFrame(frame)
            return
        }
        _state.value = _state.value.copy(frame = frame)
        if (!liveBusy.compareAndSet(false, true)) return // detector busy: this frame is only shown
        liveWorker.execute {
            try {
                process(frame, rawMs, true, display = false)
            } finally {
                liveBusy.set(false)
            }
        }
    }

    /**
     * @param rawMs timestamp of the frame in ms on a monotonic clock (video position or camera timestamp).
     * @param counting when false the frame is only displayed.
     * @param display false when the display is fed separately ([submitLive]).
     */
    fun process(frame: Bitmap, rawMs: Long, counting: Boolean, display: Boolean = true) {
        val det = detector
        if (!counting || det == null) {
            showFrame(frame)
            return
        }
        synchronized(lock) {
            // event times are relative to the start of the session (camera timestamps are device uptime)
            val start = startMs ?: rawMs.also { startMs = it }
            val tMs = rawMs - start
            lastMs = tMs

            val detections = det.detect(frame).filter { it.cls in enabledClasses && it.score >= confidence }
            val tr = tracker.update(detections, tMs)
            val aspect = frame.width / frame.height.toFloat()
            val produced = counter.update(zones, aspect, tr.active, tr.removed, tMs)

            if (saveImages) {
                for (e in produced) {
                    if (thumbs.size >= MAX_THUMBNAILS || thumbs.containsKey(e.trackId)) continue
                    val t = tr.active.firstOrNull { it.id == e.trackId } ?: continue
                    thumbnail(frame, t.box)?.let { thumbs[e.trackId] = it }
                }
            }

            val now = System.nanoTime()
            if (lastFrameNs != 0L) {
                val inst = 1e9f / (now - lastFrameNs).coerceAtLeast(1L)
                fpsEma = if (fpsEma == 0f) inst else 0.8f * fpsEma + 0.2f * inst
            }
            lastFrameNs = now

            _state.value = EngineState(if (display) frame else _state.value.frame, tr.active, counter.events, fpsEma)
        }
    }

    fun reset() = synchronized(lock) {
        tracker.reset()
        counter.reset()
        lastFrameNs = 0L
        fpsEma = 0f
        startMs = null
        lastMs = 0L
        thumbs.clear()
        _state.value = _state.value.copy(tracks = emptyList(), events = emptyList(), fps = 0f)
    }

    /** Adds the speed of vehicles still inside a zone and returns every event of the session. */
    fun finish(frameAspect: Float): EngineResult = synchronized(lock) {
        counter.finish(zones, frameAspect)
        val events = counter.events
        _state.value = _state.value.copy(events = events)
        EngineResult(events, HashMap(thumbs), lastMs)
    }

    fun close() = synchronized(lock) {
        liveWorker.shutdown()
        detector?.close()
        detector = null
    }

    companion object {
        /** Like the reference app, only the first 500 vehicle images of a session are kept. */
        const val MAX_THUMBNAILS = 500

        /** Crop around the vehicle (with some margin), at most 200 px, as JPEG. */
        private fun thumbnail(frame: Bitmap, box: RectN): ByteArray? = runCatching {
            val w = frame.width
            val h = frame.height
            val padX = box.width * 0.15f
            val padY = box.height * 0.15f
            val l = ((box.left - padX) * w).roundToInt().coerceIn(0, w - 1)
            val t = ((box.top - padY) * h).roundToInt().coerceIn(0, h - 1)
            val r = ((box.right + padX) * w).roundToInt().coerceIn(l + 1, w)
            val b = ((box.bottom + padY) * h).roundToInt().coerceIn(t + 1, h)
            if (r - l < 4 || b - t < 4) return@runCatching null
            var crop = Bitmap.createBitmap(frame, l, t, r - l, b - t)
            val scale = 200f / max(crop.width, crop.height)
            if (scale < 1f) {
                crop = Bitmap.createScaledBitmap(crop, (crop.width * scale).roundToInt().coerceAtLeast(1), (crop.height * scale).roundToInt().coerceAtLeast(1), true)
            }
            ByteArrayOutputStream().use { out ->
                crop.compress(Bitmap.CompressFormat.JPEG, 75, out)
                out.toByteArray()
            }
        }.getOrNull()
    }
}
