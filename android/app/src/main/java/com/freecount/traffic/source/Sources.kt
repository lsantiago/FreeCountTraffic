package com.freecount.traffic.source

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.freecount.traffic.ml.AnalysisEngine
import kotlinx.coroutines.ensureActive
import java.util.concurrent.Executors
import kotlin.coroutines.coroutineContext
import kotlin.math.roundToInt

enum class SourceType { CAMERA, VIDEO, RTSP }

const val FRAME_WIDTH = 640

/** Scales to at most [maxW] wide and guarantees ARGB_8888 (required by the detector). */
fun Bitmap.toAnalysisFrame(maxW: Int = FRAME_WIDTH): Bitmap {
    val scaled = if (width > maxW) {
        Bitmap.createScaledBitmap(this, maxW, (height * maxW / width.toFloat()).roundToInt().coerceAtLeast(1), true)
    } else this
    return if (scaled.config == Bitmap.Config.ARGB_8888) scaled else scaled.copy(Bitmap.Config.ARGB_8888, false)
}

/** Back camera -> engine. Frames are always forwarded; [isCounting] decides whether they are analysed. */
class CameraSource(private val context: Context, private val isCounting: () -> Boolean) {
    private val executor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null

    fun start(owner: LifecycleOwner, engine: AnalysisEngine, onError: (String) -> Unit) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                            ).build(),
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                analysis.setAnalyzer(executor) { proxy ->
                    try {
                        val raw = proxy.toBitmap()
                        val m = Matrix().apply { postRotate(proxy.imageInfo.rotationDegrees.toFloat()) }
                        val rotated = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
                        engine.process(rotated.toAnalysisFrame(), proxy.imageInfo.timestamp / 1_000_000L, isCounting())
                    } catch (t: Throwable) {
                        onError(t.message ?: t.javaClass.simpleName)
                    } finally {
                        proxy.close()
                    }
                }
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, analysis)
            } catch (t: Throwable) {
                onError(t.message ?: t.javaClass.simpleName)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun stop() {
        provider?.unbindAll()
        executor.shutdown()
    }
}

object VideoSource {
    const val STEP_MS = 100L

    /** First frame of the video, for placing zones before the run. */
    fun firstFrame(context: Context, uri: Uri): Bitmap? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(context, uri)
            val (w, h) = frameSize(r)
            r.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, w, h)?.toAnalysisFrame()
        } catch (_: Throwable) {
            null
        } finally {
            r.release()
        }
    }

    /** Recording date of the video (epoch ms) from its metadata, or null; labels intervals with real clock times. */
    fun creationTime(context: Context, uri: Uri): Long? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(context, uri)
            val raw = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE) ?: return null // e.g. 20250131T081500.000Z
            val f = java.text.SimpleDateFormat("yyyyMMdd'T'HHmmss", java.util.Locale.US)
                .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            f.parse(raw.take(15))?.time?.takeIf { it > 946_684_800_000L } // ignore 1904/1970 placeholder dates
        } catch (_: Throwable) {
            null
        } finally {
            r.release()
        }
    }

    /**
     * Steps through the video every [STEP_MS] and feeds the engine. Frame timestamps are the exact video
     * positions, so speed estimates do not depend on how fast the device processes.
     */
    suspend fun run(
        context: Context,
        uri: Uri,
        engine: AnalysisEngine,
        onProgress: (Float) -> Unit,
    ) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, uri)
            val duration = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val (w, h) = frameSize(r)
            var t = 0L
            while (t <= duration) {
                coroutineContext.ensureActive()
                val frame = r.getScaledFrameAtTime(t * 1000, MediaMetadataRetriever.OPTION_CLOSEST, w, h)
                if (frame != null) engine.process(frame.toAnalysisFrame(), t, true)
                onProgress(if (duration > 0) t / duration.toFloat() else 1f)
                t += STEP_MS
            }
        } finally {
            r.release()
        }
    }

    private fun frameSize(r: MediaMetadataRetriever): Pair<Int, Int> {
        var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 1280
        var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 720
        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        if (rot == 90 || rot == 270) { val x = w; w = h; h = x }
        val dstW = minOf(FRAME_WIDTH, w)
        return dstW to (h * dstW / w.toFloat()).roundToInt().coerceAtLeast(1)
    }
}
