package com.freecount.traffic.ml

import android.content.Context
import android.graphics.Bitmap
import com.freecount.traffic.core.Detection
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.VehicleClass
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector

/** On-device COCO object detector (EfficientDet-Lite0 via MediaPipe Tasks). Frames must be ARGB_8888. */
class VehicleDetector(context: Context, scoreThreshold: Float = 0.35f) : AutoCloseable {

    private val detector: ObjectDetector = ObjectDetector.createFromOptions(
        context,
        ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath(MODEL_ASSET).build())
            .setRunningMode(RunningMode.IMAGE)
            .setMaxResults(40)
            .setScoreThreshold(scoreThreshold)
            .build(),
    )

    fun detect(frame: Bitmap): List<Detection> {
        val w = frame.width.toFloat()
        val h = frame.height.toFloat()
        val result = detector.detect(BitmapImageBuilder(frame).build())
        return result.detections().mapNotNull { d ->
            val category = d.categories().firstOrNull() ?: return@mapNotNull null
            val cls = VehicleClass.fromCoco(category.categoryName()) ?: return@mapNotNull null
            val b = d.boundingBox()
            Detection(
                RectN(
                    (b.left / w).coerceIn(0f, 1f),
                    (b.top / h).coerceIn(0f, 1f),
                    (b.right / w).coerceIn(0f, 1f),
                    (b.bottom / h).coerceIn(0f, 1f),
                ),
                cls,
                category.score(),
            )
        }
    }

    override fun close() = detector.close()

    companion object {
        const val MODEL_ASSET = "efficientdet_lite0.tflite"
    }
}
