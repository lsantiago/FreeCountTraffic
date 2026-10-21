package com.freecount.traffic.core

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

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
    /** Mean detection confidence of the winning class (0..1). */
    val score: Float = 0f,
)

/** One of 8 screen directions (y grows downwards), used to count only the traffic going one way. */
enum class Heading(val arrow: String, val degrees: Float) {
    N("↑", 270f), NE("↗", 315f), E("→", 0f), SE("↘", 45f), S("↓", 90f), SW("↙", 135f), W("←", 180f), NW("↖", 225f);

    /** True when a movement (in pixel-proportional units) points within [toleranceDeg] of this heading. */
    fun accepts(dx: Float, dy: Float, toleranceDeg: Float = 67.5f): Boolean {
        var diff = abs(Math.toDegrees(atan2(dy, dx).toDouble()).toFloat() - degrees) % 360f
        if (diff > 180f) diff = 360f - diff
        return diff <= toleranceDeg
    }
}

/**
 * A user-drawn counting box. [lengthMeters] is the real-world length of the box along its long axis (for speed).
 * [direction] (optional) counts only vehicles moving that way.
 */
data class Zone(
    val id: Int,
    val name: String,
    /** The box before rotation (normalized frame coordinates). */
    val rect: RectN,
    val lengthMeters: Float? = null,
    val direction: Heading? = null,
    /**
     * Clockwise rotation of the box around its centre, in radians. The rotation is applied in pixel space, so the box
     * keeps its shape on screen whatever the frame aspect.
     */
    val angle: Float = 0f,
) {
    /** Unit vector of the box's width axis in pixel-proportional space (x scaled by the frame aspect). */
    val axisCos: Float get() = cos(angle)
    val axisSin: Float get() = sin(angle)

    /** A point in the box's own frame: u along its width, v along its height, both within -0.5..0.5 inside the box. */
    fun local(x: Float, y: Float, frameAspect: Float): Pair<Float, Float> {
        val dx = (x - rect.cx) * frameAspect
        val dy = y - rect.cy
        val rx = dx * axisCos + dy * axisSin
        val ry = -dx * axisSin + dy * axisCos
        return Pair(rx / max(rect.width * frameAspect, 1e-6f), ry / max(rect.height, 1e-6f))
    }

    fun contains(x: Float, y: Float, frameAspect: Float): Boolean {
        if (angle == 0f) return rect.contains(x, y)
        val (u, v) = local(x, y, frameAspect)
        return abs(u) <= 0.5f && abs(v) <= 0.5f
    }
}

/**
 * One counted vehicle. [direction] is an arrow: "→" "←" (horizontal zone) or "↓" "↑" (vertical zone).
 * [timeMs] is the moment the vehicle entered the box, relative to the start of the session.
 */
data class CountEvent(
    val zoneId: Int,
    val zoneName: String,
    val trackId: Int,
    val cls: VehicleClass,
    val direction: String,
    val speedKmh: Float?,
    val timeMs: Long,
    val score: Float? = null,
)
