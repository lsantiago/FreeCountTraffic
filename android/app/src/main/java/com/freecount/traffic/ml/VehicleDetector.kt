package com.freecount.traffic.ml

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import com.freecount.traffic.core.Detection
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.VehicleClass
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Accuracy / speed trade-offs, like the reference app's "Detection Model" setting (same models as the iOS app). */
enum class DetectionModel(val title: String, val asset: String) {
    BALANCED("Balanced", "yolo11s.tflite"),
    FASTEST("Fastest", "yolo11n.tflite"),
}

/**
 * On-device COCO object detector: an Ultralytics YOLO11 model exported to TensorFlow Lite by
 * `scripts/export-models.sh` (640x640 RGB input, raw [1, 84, 8400] output). The frame is letterboxed into the
 * square input; boxes are decoded, filtered to the classes we count and de-duplicated with class-agnostic NMS
 * (so one vehicle never becomes both a car and a truck).
 */
class VehicleDetector(
    context: Context,
    model: DetectionModel = DetectionModel.BALANCED,
    private val scoreThreshold: Float = 0.10f,
) : AutoCloseable {

    private val interpreter: Interpreter
    private val size: Int
    private val input: ByteBuffer
    private val pixels: IntArray
    private val letterbox: Bitmap
    private val outShape: IntArray
    private val output: Array<Array<FloatArray>>

    init {
        val fd = context.assets.openFd(model.asset)
        val buffer = FileInputStream(fd.fileDescriptor).channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
        interpreter = Interpreter(buffer, Interpreter.Options().setNumThreads(4))
        size = interpreter.getInputTensor(0).shape()[1]
        input = ByteBuffer.allocateDirect(size * size * 3 * 4).order(ByteOrder.nativeOrder())
        pixels = IntArray(size * size)
        letterbox = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        outShape = interpreter.getOutputTensor(0).shape() // [1, 84, 8400] (or [1, 8400, 84])
        output = Array(1) { Array(outShape[1]) { FloatArray(outShape[2]) } }
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
        input.rewind()
        for (p in pixels) {
            input.putFloat(((p shr 16) and 0xFF) / 255f)
            input.putFloat(((p shr 8) and 0xFF) / 255f)
            input.putFloat((p and 0xFF) / 255f)
        }
        input.rewind()
        interpreter.run(input, output)

        val channelsFirst = outShape[1] < outShape[2]
        val n = if (channelsFirst) outShape[2] else outShape[1]
        val o = output[0]
        fun v(c: Int, i: Int) = if (channelsFirst) o[c][i] else o[i][c]

        // boxes are normalized to the input (0..1) in current exports; older ones use pixels
        var maxCoord = 0f
        for (i in 0 until min(n, 64)) maxCoord = max(maxCoord, v(0, i))
        val unit = if (maxCoord > 2f) 1f else size.toFloat()

        val candidates = ArrayList<Detection>()
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
        return nms(candidates)
    }

    override fun close() = interpreter.close()

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
