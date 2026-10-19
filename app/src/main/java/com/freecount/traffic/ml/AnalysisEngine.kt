package com.freecount.traffic.ml

import android.content.Context
import android.graphics.Bitmap
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.SimpleTracker
import com.freecount.traffic.core.Track
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone
import com.freecount.traffic.core.ZoneCounter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class EngineState(
    val frame: Bitmap? = null,
    val tracks: List<Track> = emptyList(),
    val events: List<CountEvent> = emptyList(),
    val fps: Float = 0f,
)

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

    @Volatile var zones: List<Zone> = emptyList()
    @Volatile var enabledClasses: Set<VehicleClass> = setOf(
        VehicleClass.CAR, VehicleClass.TRUCK, VehicleClass.BUS, VehicleClass.MOTORCYCLE,
    )

    private val _state = MutableStateFlow(EngineState())
    val state: StateFlow<EngineState> = _state

    /** Loads the model. Call off the main thread. */
    fun init() = synchronized(lock) {
        if (detector == null) detector = VehicleDetector(context)
    }

    val isReady: Boolean get() = detector != null

    /** Show a frame without detecting (camera/video preview before the session starts). */
    fun showFrame(frame: Bitmap) {
        _state.value = _state.value.copy(frame = frame, tracks = emptyList())
    }

    /**
     * @param tMs timestamp of the frame in ms on a monotonic clock (video position or camera timestamp).
     * @param counting when false the frame is only displayed.
     */
    fun process(frame: Bitmap, tMs: Long, counting: Boolean) {
        val det = detector
        if (!counting || det == null) {
            showFrame(frame)
            return
        }
        synchronized(lock) {
            val detections = det.detect(frame).filter { it.cls in enabledClasses }
            val tr = tracker.update(detections, tMs)
            val aspect = frame.width / frame.height.toFloat()
            counter.update(zones, aspect, tr.active, tr.removed, tMs)

            val now = System.nanoTime()
            if (lastFrameNs != 0L) {
                val inst = 1e9f / (now - lastFrameNs).coerceAtLeast(1L)
                fpsEma = if (fpsEma == 0f) inst else 0.8f * fpsEma + 0.2f * inst
            }
            lastFrameNs = now

            _state.value = EngineState(frame, tr.active, counter.events, fpsEma)
        }
    }

    fun reset() = synchronized(lock) {
        tracker.reset()
        counter.reset()
        lastFrameNs = 0L
        fpsEma = 0f
        _state.value = _state.value.copy(tracks = emptyList(), events = emptyList(), fps = 0f)
    }

    /** Flush vehicles still inside a zone and return every event of the session. */
    fun finish(frameAspect: Float): List<CountEvent> = synchronized(lock) {
        counter.finish(zones, frameAspect)
        val events = counter.events
        _state.value = _state.value.copy(events = events)
        events
    }

    fun close() = synchronized(lock) {
        detector?.close()
        detector = null
    }
}
