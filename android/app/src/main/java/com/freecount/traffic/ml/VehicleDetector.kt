package com.freecount.traffic.ml

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import com.freecount.traffic.core.Detection
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.VehicleClass
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Accuracy / speed trade-offs, like the reference app's "Detection Model" setting (same models as the iOS app). */
enum class DetectionModel(val title: String, val asset: String) {
    BALANCED("Balanced", "yolo11s.onnx"),
    FASTEST("Fastest", "yolo11n.onnx"),
}

/** Detector input side in pixels: smaller is much faster (cost grows with the square) but misses distant vehicles. */
enum class InputSize(val px: Int, val title: String) {
    LARGE(640, "640 (accurate)"),
    MEDIUM(480, "480"),
    SMALL(320, "320 (fast)"),
}

/**
 * On-device COCO object detector: an Ultralytics YOLO11 model exported to ONNX by `scripts/export-models.sh`
 * (dynamic-size RGB NCHW input, raw [1, 84, N] output) and run with ONNX Runtime, on XNNPACK when available.
 * The frame is letterboxed into the square input; boxes are decoded, filtered to the classes we count and
 * de-duplicated with class-agnostic NMS (so one vehicle never becomes both a car and a truck).
 */
class VehicleDetector(
    context: Context,
    model: DetectionModel = DetectionModel.FASTEST,
    inputSize: InputSize = InputSize.MEDIUM,
    private val scoreThreshold: Float = 0.10f,
) : AutoCloseable {

    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession
    private val inputName: String
    private val size = inputSize.px
    private val input = FloatBuffer.allocate(3 * size * size)
    private val pixels = IntArray(size * size)
    private val letterbox = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)

    init {
        val bytes = context.assets.open(model.asset).use { it.readBytes() }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
        session = try {
            // XNNPACK: optimized CPU kernels, recommended by ONNX Runtime for non-quantized models on mobile.
            // It manages its own thread pool, so ONNX Runtime's intra-op pool is kept to one thread.
            val xnn = OrtSession.SessionOptions().apply {
                addXnnpack(mapOf("intra_op_num_threads" to threads.toString()))
                setIntraOpNumThreads(1)
            }
            env.createSession(bytes, xnn)
        } catch (_: Throwable) {
            env.createSession(bytes, OrtSession.SessionOptions().apply { setIntraOpNumThreads(threads) })
        }
        inputName = session.inputNames.first()
    }

    fun detect(frame: Bitmap): List<Detection> {
        // letterbox: keep the aspect ratio, pad with grey
        val scale = min(size / frame.width.toFloat(), size / frame.height.toFloat())
        val w = (frame.width * scale).roundToInt()
        val h = (frame.height * scale).roundToInt()
        val padX = (size - w) / 2
        val padY = (size - h) / 2
        Canvas(letterbox).apply {
            drawColor(Color.rgb(114, 114, 114))
            drawBitmap(frame, null, Rect(padX, padY, padX + w, padY + h), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        letterbox.getPixels(pixels, 0, size, 0, 0, size, size)
        // NCHW, RGB, 0..1
        val plane = size * size
        val arr = input.array()
        for (i in 0 until plane) {
            val p = pixels[i]
            arr[i] = ((p shr 16) and 0xFF) / 255f
            arr[plane + i] = ((p shr 8) and 0xFF) / 255f
            arr[2 * plane + i] = (p and 0xFF) / 255f
        }
        input.rewind()

        val candidates = ArrayList<Detection>()
        OnnxTensor.createTensor(env, input, longArrayOf(1, 3, size.toLong(), size.toLong())).use { tensor ->
            session.run(mapOf(inputName to tensor)).use { result ->
                @Suppress("UNCHECKED_CAST")
                val o = (result[0].value as Array<Array<FloatArray>>)[0]
                val channelsFirst = o.size < o[0].size // [84][8400] (or [8400][84])
                val n = if (channelsFirst) o[0].size else o.size
                fun v(c: Int, i: Int) = if (channelsFirst) o[c][i] else o[i][c]

                // ONNX boxes are in input pixels; some exports normalize them to 0..1
                var maxCoord = 0f
                for (i in 0 until min(n, 64)) maxCoord = max(maxCoord, v(0, i))
                val unit = if (maxCoord > 2f) 1f else size.toFloat()

                for (i in 0 until n) {
                    var best = -1
                    var bestScore = scoreThreshold
                    for (k in COCO_IDS.indices) {
                        val s = v(4 + COCO_IDS[k], i)
                        if (s > bestScore) { bestScore = s; best = k }
                    }
                    if (best < 0) continue
                    val cx = v(0, i) * unit
                    val cy = v(1, i) * unit
                    val bw = v(2, i) * unit
                    val bh = v(3, i) * unit
                    // back from the letterboxed square to the frame, normalized
                    val l = ((cx - bw / 2 - padX) / w).coerceIn(0f, 1f)
                    val t = ((cy - bh / 2 - padY) / h).coerceIn(0f, 1f)
                    val r = ((cx + bw / 2 - padX) / w).coerceIn(0f, 1f)
                    val b = ((cy + bh / 2 - padY) / h).coerceIn(0f, 1f)
                    if (r - l <= 0f || b - t <= 0f) continue
                    candidates += Detection(RectN(l, t, r, b), CLASSES[best], bestScore)
                }
            }
        }
        return nms(candidates)
    }

    override fun close() = session.close()

    companion object {
        /** COCO indices of the classes we count (YOLO output channel = 4 + index). */
        private val COCO_IDS = intArrayOf(0, 1, 2, 3, 5, 7)
        private val CLASSES = arrayOf(
            VehicleClass.PERSON, VehicleClass.BICYCLE, VehicleClass.CAR,
            VehicleClass.MOTORCYCLE, VehicleClass.BUS, VehicleClass.TRUCK,
        )

        private fun nms(dets: List<Detection>, iou: Float = 0.45f, maxDet: Int = 100): List<Detection> {
            val sorted = dets.sortedByDescending { it.score }
            val kept = ArrayList<Detection>()
            for (d in sorted) {
                if (kept.size >= maxDet) break
                if (kept.none { it.box.iou(d.box) > iou }) kept += d
            }
            return kept
        }
    }
}
