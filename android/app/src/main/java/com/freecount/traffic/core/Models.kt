package com.freecount.traffic.core

import kotlin.math.max
import kotlin.math.min

enum class VehicleClass(val label: String) {
    CAR("Car"),
    TRUCK("Truck"),
    BUS("Bus"),
    MOTORCYCLE("Motorcycle"),
    BICYCLE("Bicycle"),
    PERSON("Person");

    companion object {
        fun fromCoco(name: String): VehicleClass? = when (name.lowercase()) {
            "car" -> CAR
            "truck" -> TRUCK
            "bus" -> BUS
            "motorcycle" -> MOTORCYCLE
            "bicycle" -> BICYCLE
            "person" -> PERSON
            else -> null
        }
    }
}

/** Axis-aligned rectangle in normalized (0..1) frame coordinates. */
data class RectN(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    val cx: Float get() = (left + right) / 2f
    val cy: Float get() = (top + bottom) / 2f

    fun contains(x: Float, y: Float): Boolean = x in left..right && y in top..bottom

    fun shifted(dx: Float, dy: Float) = RectN(left + dx, top + dy, right + dx, bottom + dy)

    fun iou(o: RectN): Float {
        val iw = min(right, o.right) - max(left, o.left)
        val ih = min(bottom, o.bottom) - max(top, o.top)
        if (iw <= 0f || ih <= 0f) return 0f
        val inter = iw * ih
        val union = width * height + o.width * o.height - inter
        return if (union <= 0f) 0f else inter / union
    }
}

data class Detection(val box: RectN, val cls: VehicleClass, val score: Float)

/** Snapshot of a tracked object. Times are in milliseconds on the source's clock. */
data class Track(
    val id: Int,
    val box: RectN,
    val cls: VehicleClass,
    val hits: Int,
    val firstSeenMs: Long,
    val lastSeenMs: Long,
)

/** A user-drawn counting box. [lengthMeters] is the real-world length of the box along its long axis (for speed). */
data class Zone(
    val id: Int,
    val name: String,
    val rect: RectN,
    val lengthMeters: Float? = null,
)

/** One counted vehicle. [direction] is an arrow: "→" "←" (horizontal zone) or "↓" "↑" (vertical zone). */
data class CountEvent(
    val zoneId: Int,
    val zoneName: String,
    val trackId: Int,
    val cls: VehicleClass,
    val direction: String,
    val speedKmh: Float?,
    val timeMs: Long,
)
