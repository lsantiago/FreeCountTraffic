package com.freecount.traffic.source

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.freecount.traffic.ml.AnalysisEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import java.util.concurrent.Executors
import kotlin.coroutines.coroutineContext
import kotlin.math.max
import kotlin.math.min
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
                        engine.submitLive(rotated.toAnalysisFrame(), proxy.imageInfo.timestamp / 1_000_000L, isCounting())
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

    /** Never analyse more than ~33 frames per second of video. */
    const val MIN_GAP_MS = 30L

    /**
     * Plays the video at real speed through the hardware decoder, like a live camera (same rule as the iOS app):
     * frames the device has no time for are dropped, but never more than [STEP_MS] apart, so a slow phone plays
     * slower than real time instead of losing vehicles. Timestamps are the exact video positions, so speed
     * estimates do not depend on how fast the device processes. Falls back to frame-by-frame seeking if the
     * decoder cannot be used.
     */
    suspend fun run(
        context: Context,
        uri: Uri,
        engine: AnalysisEngine,
        onProgress: (Float) -> Unit,
    ) {
        var analysed = 0
        try {
            decodeSequentially(context, uri, engine, onProgress) { analysed++ }
            if (analysed > 0) return
            Log.w("VideoSource", "decoder produced no frames, using frame seeking")
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            if (analysed > 0) throw t
            Log.w("VideoSource", "decoder failed, using frame seeking", t)
        }
        runWithSeeking(context, uri, engine, onProgress)
    }

    private suspend fun decodeSequentially(
        context: Context,
        uri: Uri,
        engine: AnalysisEngine,
        onProgress: (Float) -> Unit,
        onFrame: () -> Unit,
    ) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: error("no video track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            val rotation = rotationOf(context, uri)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val c = MediaCodec.createDecoderByType(mime).also { codec = it }
            c.configure(format, null, null, 0)
            c.start()

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var lastMs = -STEP_MS
            var originMs = -1L
            var clockStart = 0L
            while (!outputDone) {
                coroutineContext.ensureActive()
                if (!inputDone) {
                    val inIdx = c.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val n = extractor.readSampleData(c.getInputBuffer(inIdx)!!, 0)
                        if (n < 0) {
                            c.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            c.queueInputBuffer(inIdx, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = c.dequeueOutputBuffer(info, 10_000)
                if (outIdx < 0) continue
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                val ms = info.presentationTimeUs / 1000
                var use = info.size > 0 && ms >= lastMs + MIN_GAP_MS
                if (use) {
                    val now = SystemClock.elapsedRealtime()
                    if (originMs < 0) { originMs = ms; clockStart = now }
                    val videoElapsed = ms - originMs
                    val wallElapsed = now - clockStart
                    if (videoElapsed < wallElapsed) {
                        // behind real time: drop this frame unless tracking would get too sparse
                        if (ms < lastMs + STEP_MS) use = false
                        else if (wallElapsed - videoElapsed > 250) clockStart = now - videoElapsed // do not race to catch up
                    } else if (videoElapsed > wallElapsed) {
                        delay(videoElapsed - wallElapsed)
                    }
                }
                if (use) {
                    // only the frames we analyse are converted, already downscaled to the analysis size
                    val frame = c.getOutputImage(outIdx)?.use { yuvToFrame(it, rotation) }
                    c.releaseOutputBuffer(outIdx, false)
                    if (frame != null) {
                        engine.process(frame, ms, true)
                        onFrame()
                        lastMs = ms
                        if (durationUs > 0) onProgress((ms * 1000f / durationUs).coerceIn(0f, 1f))
                    }
                } else {
                    c.releaseOutputBuffer(outIdx, false)
                }
            }
            onProgress(1f)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            extractor.release()
        }
    }

    private fun rotationOf(context: Context, uri: Uri): Int {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(context, uri)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } catch (_: Throwable) {
            0
        } finally {
            r.release()
        }
    }

    /** YUV 4:2:0 decoder output -> ARGB frame at most [FRAME_WIDTH] wide (nearest sampling), rotated upright. */
    private fun yuvToFrame(image: Image, rotation: Int): Bitmap {
        val crop = image.cropRect
        val srcW = crop.width()
        val srcH = crop.height()
        val uprightW = if (rotation == 90 || rotation == 270) srcH else srcW
        val s = min(1f, FRAME_WIDTH / uprightW.toFloat())
        val outW = (srcW * s).roundToInt().coerceAtLeast(1)
        val outH = (srcH * s).roundToInt().coerceAtLeast(1)
        val (yP, uP, vP) = image.planes
        val yB = yP.buffer
        val uB = uP.buffer
        val vB = vP.buffer
        val out = IntArray(outW * outH)
        for (oy in 0 until outH) {
            val sy = crop.top + oy * srcH / outH
            val yRow = sy * yP.rowStride
            val uRow = (sy / 2) * uP.rowStride
            val vRow = (sy / 2) * vP.rowStride
            for (ox in 0 until outW) {
                val sx = crop.left + ox * srcW / outW
                val y = (yB.get(yRow + sx * yP.pixelStride).toInt() and 0xFF) - 16
                val u = (uB.get(uRow + (sx / 2) * uP.pixelStride).toInt() and 0xFF) - 128
                val v = (vB.get(vRow + (sx / 2) * vP.pixelStride).toInt() and 0xFF) - 128
                val yy = 1192 * max(y, 0)
                val r = ((yy + 1634 * v) shr 10).coerceIn(0, 255)
                val g = ((yy - 833 * v - 400 * u) shr 10).coerceIn(0, 255)
                val b = ((yy + 2066 * u) shr 10).coerceIn(0, 255)
                out[oy * outW + ox] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        val bmp = Bitmap.createBitmap(out, outW, outH, Bitmap.Config.ARGB_8888)
        if (rotation == 0) return bmp
        val m = Matrix().apply { postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(bmp, 0, 0, outW, outH, m, true)
    }

    /** Old path: seek to every [STEP_MS] (decodes from the previous key frame each time, so it is slow). */
    private suspend fun runWithSeeking(
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
