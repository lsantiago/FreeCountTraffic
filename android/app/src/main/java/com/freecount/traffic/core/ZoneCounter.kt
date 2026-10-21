package com.freecount.traffic.core

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Counts tracks passing through user-defined zones and estimates their speed.
 *
 * Like the reference app, a vehicle is counted as soon as its centre point enters a zone, once per zone and track,
 * provided it is moving (at least [minMove] of the frame height over the last [motionWindowMs]; parked vehicles are
 * never counted). If the zone has a [Zone.direction], vehicles moving another way are ignored.
 * The event's arrow is the sign of the movement along the zone's long axis.
 * Speed is added to the event when the vehicle leaves the zone (or its track ends inside it) after travelling at
 * least [minProgress] of the zone length: zone length (m) * travelled fraction / time inside.
 * Same algorithm as the iOS app's ZoneCounter.
 */
class ZoneCounter(
    private val minProgress: Float = 0.25f,
    private val minMove: Float = 0.02f,
    private val motionWindowMs: Long = 1500,
) {
    private class InZone(val entryPos: Float, val entryMs: Long, var lastPos: Float, var lastMs: Long)

    private class Point(val x: Float, val y: Float, val t: Long)

    private val states = HashMap<Pair<Int, Int>, InZone>()

    /** Zone/track pairs already decided: counted -> event index, rejected by the direction filter -> null. */
    private val decided = HashMap<Pair<Int, Int>, Int?>()
    private val motion = HashMap<Int, ArrayDeque<Point>>()
    private val all = ArrayList<CountEvent>()

    val events: List<CountEvent> get() = all.toList()

    fun reset() {
        states.clear()
        decided.clear()
        motion.clear()
        all.clear()
    }

    /** @return the events produced (vehicles counted) by this update. */
    fun update(
        zones: List<Zone>,
        frameAspect: Float,
        active: List<Track>,
        removed: List<Track>,
        tMs: Long,
    ): List<CountEvent> {
        val produced = mutableListOf<CountEvent>()
        val zoneIds = zones.map { it.id }.toSet()
        states.keys.filter { it.first !in zoneIds }.forEach { states.remove(it) }

        for (t in active) {
            if (t.lastSeenMs != tMs) continue // coasting, no fresh position
            val pts = motion.getOrPut(t.id) { ArrayDeque() }
            pts.addLast(Point(t.box.cx, t.box.cy, tMs))
            while (tMs - pts.first().t > motionWindowMs) pts.removeFirst()
            // movement in pixel-proportional units (x scaled by the frame aspect), relative to the frame height
            val dx = (pts.last().x - pts.first().x) * frameAspect
            val dy = pts.last().y - pts.first().y
            val moving = hypot(dx, dy) >= minMove

            for (z in zones) {
                val key = z.id to t.id
                val horizontal = isHorizontal(z, frameAspect)
                if (z.contains(t.box.cx, t.box.cy, frameAspect)) {
                    // position along the long axis as a fraction of the box length (boxes may be rotated)
                    val (u, v) = z.local(t.box.cx, t.box.cy, frameAspect)
                    val pos = if (horizontal) u else v
                    val st = states[key]
                    if (st == null) states[key] = InZone(pos, tMs, pos, tMs) else {
                        st.lastPos = pos
                        st.lastMs = tMs
                    }
                    if (!decided.containsKey(key) && moving) {
                        val want = z.direction
                        if (want != null && !want.accepts(dx, dy)) {
                            decided[key] = null
                        } else {
                            val along = if (horizontal) dx * z.axisCos + dy * z.axisSin else -dx * z.axisSin + dy * z.axisCos
                            val arrow = if (horizontal) (if (along >= 0f) "→" else "←") else (if (along >= 0f) "↓" else "↑")
                            val e = CountEvent(z.id, z.name, t.id, t.cls, arrow, null, tMs, t.score)
                            decided[key] = all.size
                            all += e
                            produced += e
                        }
                    }
                } else {
                    states.remove(key)?.let { addSpeed(z, horizontal, key, it) }
                }
            }
        }

        for (t in removed) {
            for (z in zones) {
                val key = z.id to t.id
                states.remove(key)?.let { addSpeed(z, isHorizontal(z, frameAspect), key, it) }
                decided.remove(key)
            }
            motion.remove(t.id)
        }
        return produced
    }

    /** End of session: add the speed of vehicles still inside a zone. */
    fun finish(zones: List<Zone>, frameAspect: Float) {
        for ((key, st) in states.entries.toList()) {
            val z = zones.firstOrNull { it.id == key.first } ?: continue
            addSpeed(z, isHorizontal(z, frameAspect), key, st)
        }
        states.clear()
    }

    private fun addSpeed(z: Zone, horizontal: Boolean, key: Pair<Int, Int>, st: InZone) {
        val index = decided[key] ?: return
        if (index >= all.size) return
        val len = z.lengthMeters ?: return
        if (len <= 0f) return
        val progress = abs(st.lastPos - st.entryPos)
        val dtSec = (st.lastMs - st.entryMs) / 1000f
        if (progress >= minProgress && dtSec > 0.2f) {
            all[index] = all[index].copy(speedKmh = len * progress / dtSec * 3.6f)
        }
    }

    companion object {
        fun isHorizontal(z: Zone, frameAspect: Float): Boolean = z.rect.width * frameAspect >= z.rect.height
    }
}
