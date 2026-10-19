package com.freecount.traffic.core

import kotlin.math.hypot
import kotlin.math.max

data class TrackerResult(
    /** Confirmed tracks that are still alive (including ones briefly not detected). */
    val active: List<Track>,
    /** Confirmed tracks dropped in this update. */
    val removed: List<Track>,
)

/**
 * Greedy IoU / centroid tracker with constant-velocity prediction and class voting.
 * Good enough for roadside cameras at 5-15 fps; no external dependencies.
 */
class SimpleTracker(
    private val maxAgeMs: Long = 1200,
    private val minHits: Int = 2,
) {
    private class State(
        val id: Int,
        var box: RectN,
        var vx: Float,
        var vy: Float,
        val first: Long,
        var last: Long,
        var hits: Int,
        /** class -> sum of scores */
        val votes: MutableMap<VehicleClass, Float>,
        /** class -> number of detections */
        val votesN: MutableMap<VehicleClass, Int>,
    ) {
        fun snapshot(): Track {
            val best = votes.maxByOrNull { it.value }!!
            return Track(id, box, best.key, hits, first, last, best.value / (votesN[best.key] ?: 1))
        }
    }

    private val states = mutableListOf<State>()
    private var nextId = 1

    fun reset() {
        states.clear()
        nextId = 1
    }

    fun update(detections: List<Detection>, tMs: Long): TrackerResult {
        val candidates = ArrayList<Triple<Float, Int, Int>>()
        for ((i, s) in states.withIndex()) {
            val dt = (tMs - s.last).coerceAtLeast(0L).toFloat()
            val predicted = s.box.shifted(s.vx * dt, s.vy * dt)
            for ((j, d) in detections.withIndex()) {
                val dist = hypot(predicted.cx - d.box.cx, predicted.cy - d.box.cy)
                val size = max(max(s.box.width, s.box.height), max(d.box.width, d.box.height))
                val iou = predicted.iou(d.box)
                if (iou >= 0.1f || dist <= 0.75f * size) {
                    candidates += Triple(dist / size - iou, i, j)
                }
            }
        }
        candidates.sortBy { it.first }

        val usedTracks = HashSet<Int>()
        val usedDets = HashSet<Int>()
        for ((_, i, j) in candidates) {
            if (i in usedTracks || j in usedDets) continue
            usedTracks += i
            usedDets += j
            val s = states[i]
            val d = detections[j]
            val dt = (tMs - s.last).toFloat()
            if (dt > 0f) {
                s.vx = 0.5f * s.vx + 0.5f * (d.box.cx - s.box.cx) / dt
                s.vy = 0.5f * s.vy + 0.5f * (d.box.cy - s.box.cy) / dt
            }
            s.box = d.box
            s.last = tMs
            s.hits++
            s.votes[d.cls] = (s.votes[d.cls] ?: 0f) + d.score
            s.votesN[d.cls] = (s.votesN[d.cls] ?: 0) + 1
        }

        val removed = mutableListOf<Track>()
        val survivors = mutableListOf<State>()
        for ((i, s) in states.withIndex()) {
            if (i in usedTracks || tMs - s.last <= maxAgeMs) {
                survivors += s
            } else if (s.hits >= minHits) {
                removed += s.snapshot()
            }
        }
        states.clear()
        states.addAll(survivors)

        for ((j, d) in detections.withIndex()) {
            if (j in usedDets) continue
            states += State(nextId++, d.box, 0f, 0f, tMs, tMs, 1, mutableMapOf(d.cls to d.score), mutableMapOf(d.cls to 1))
        }

        return TrackerResult(
            active = states.filter { it.hits >= minHits }.map { it.snapshot() },
            removed = removed,
        )
    }
}
