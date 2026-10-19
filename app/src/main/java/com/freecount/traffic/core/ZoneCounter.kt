package com.freecount.traffic.core

import kotlin.math.abs

/**
 * Counts tracks passing through user-defined zones and estimates their speed.
 *
 * A vehicle is counted when it leaves a zone (or its track ends inside it) after having travelled at least
 * [minProgress] of the zone length along the zone's long axis. Direction is the sign of that travel.
 * Speed = zone length (m) * travelled fraction / time inside, so [Zone.lengthMeters] must be set for speed.
 */
class ZoneCounter(private val minProgress: Float = 0.25f) {

    private class InZone(
        val entryPos: Float,
        val entryMs: Long,
        var lastPos: Float,
        var lastMs: Long,
        var cls: VehicleClass,
    )

    private val states = HashMap<Pair<Int, Int>, InZone>()
    private val all = ArrayList<CountEvent>()

    val events: List<CountEvent> get() = all.toList()

    fun reset() {
        states.clear()
        all.clear()
    }

    /** @return the events produced by this update. */
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

        for (z in zones) {
            val horizontal = isHorizontal(z, frameAspect)
            for (t in active) {
                if (t.lastSeenMs != tMs) continue // coasting, no fresh position
                val key = z.id to t.id
                val inside = z.rect.contains(t.box.cx, t.box.cy)
                val st = states[key]
                if (inside) {
                    val pos = axisPos(horizontal, t)
                    if (st == null) {
                        states[key] = InZone(pos, tMs, pos, tMs, t.cls)
                    } else {
                        st.lastPos = pos
                        st.lastMs = tMs
                        st.cls = t.cls
                    }
                } else if (st != null) {
                    finish(z, horizontal, t.id, st)?.let { produced += it }
                    states.remove(key)
                }
            }
        }

        for (t in removed) {
            for (z in zones) {
                val st = states.remove(z.id to t.id) ?: continue
                finish(z, isHorizontal(z, frameAspect), t.id, st)?.let { produced += it }
            }
        }
        all += produced
        return produced
    }

    /** Flush vehicles still inside a zone (end of session). */
    fun finish(zones: List<Zone>, frameAspect: Float): List<CountEvent> {
        val produced = mutableListOf<CountEvent>()
        for ((key, st) in states.entries.toList()) {
            val z = zones.firstOrNull { it.id == key.first } ?: continue
            finish(z, isHorizontal(z, frameAspect), key.second, st)?.let { produced += it }
        }
        states.clear()
        all += produced
        return produced
    }

    private fun finish(z: Zone, horizontal: Boolean, trackId: Int, st: InZone): CountEvent? {
        val axisLen = if (horizontal) z.rect.width else z.rect.height
        if (axisLen <= 0f) return null
        val progress = (st.lastPos - st.entryPos) / axisLen
        if (abs(progress) < minProgress) return null
        val forward = progress > 0f
        val arrow = if (horizontal) (if (forward) "→" else "←") else (if (forward) "↓" else "↑")
        val dtSec = (st.lastMs - st.entryMs) / 1000f
        val speed = z.lengthMeters?.takeIf { it > 0f && dtSec > 0.2f }?.let {
            it * abs(progress) / dtSec * 3.6f
        }
        return CountEvent(z.id, z.name, trackId, st.cls, arrow, speed, st.lastMs)
    }

    companion object {
        fun isHorizontal(z: Zone, frameAspect: Float): Boolean = z.rect.width * frameAspect >= z.rect.height

        private fun axisPos(horizontal: Boolean, t: Track): Float = if (horizontal) t.box.cx else t.box.cy
    }
}
