package com.freecount.traffic.core

import java.util.Locale

data class ZoneSummary(
    val zoneId: Int,
    val zoneName: String,
    val total: Int,
    val byClass: Map<VehicleClass, Int>,
    val byDirection: Map<String, Int>,
    val avgSpeedKmh: Float?,
    val maxSpeedKmh: Float?,
)

data class IntervalRow(val startMs: Long, val endMs: Long, val byClass: Map<VehicleClass, Int>) {
    val total: Int get() = byClass.values.sum()
}

data class PeakHour(val startMs: Long, val volume: Int, val phf: Float?)

object Summary {
    /** One event per vehicle (its first one): a vehicle crossing several boxes is counted once. */
    fun unique(events: List<CountEvent>): List<CountEvent> {
        val seen = HashSet<Int>()
        return events.sortedBy { it.timeMs }.filter { seen.add(it.trackId) }
    }

    fun byClass(events: List<CountEvent>): Map<VehicleClass, Int> = events.groupingBy { it.cls }.eachCount()

    /**
     * Counts per time interval. [zoneId] null = unique vehicles over all boxes.
     * Every interval from the start of the session to [durationMs] is listed, empty ones included.
     */
    fun intervals(events: List<CountEvent>, intervalMs: Long, durationMs: Long, zoneId: Int? = null): List<IntervalRow> {
        if (intervalMs <= 0) return emptyList()
        val selected = if (zoneId != null) events.filter { it.zoneId == zoneId } else unique(events)
        val last = maxOf(durationMs, (selected.maxOfOrNull { it.timeMs } ?: 0L) + 1)
        val n = ((last + intervalMs - 1) / intervalMs).toInt().coerceAtLeast(1)
        val counts = List(n) { HashMap<VehicleClass, Int>() }
        for (e in selected) {
            val i = (e.timeMs.coerceAtLeast(0) / intervalMs).toInt().coerceAtMost(n - 1)
            counts[i][e.cls] = (counts[i][e.cls] ?: 0) + 1
        }
        return counts.mapIndexed { i, m -> IntervalRow(i * intervalMs, (i + 1) * intervalMs, m) }
    }

    /**
     * Busiest 60 minutes on a 15-minute grid, with the peak hour factor PHF = V / (4 * V15max).
     * Null for sessions shorter than an hour.
     */
    fun peakHour(events: List<CountEvent>, durationMs: Long, zoneId: Int? = null): PeakHour? {
        val q = 15 * 60 * 1000L
        if (durationMs < 4 * q) return null
        val rows = intervals(events, q, durationMs, zoneId)
        if (rows.size < 4) return null
        var best: PeakHour? = null
        for (i in 0..rows.size - 4) {
            val window = rows.subList(i, i + 4)
            val volume = window.sumOf { it.total }
            if (best == null || volume > best.volume) {
                val maxQ = window.maxOf { it.total }
                best = PeakHour(rows[i].startMs, volume, if (maxQ > 0) volume.toFloat() / (4 * maxQ) else null)
            }
        }
        return best
    }

    /** Per-zone totals; zones with no events are listed with zeros when [zones] is given. */
    fun of(events: List<CountEvent>, zones: List<Zone> = emptyList()): List<ZoneSummary> {
        val names = linkedMapOf<Int, String>()
        zones.forEach { names[it.id] = it.name }
        events.forEach { names.putIfAbsent(it.zoneId, it.zoneName) }
        return names.map { (id, name) ->
            val ev = events.filter { it.zoneId == id }
            val speeds = ev.mapNotNull { it.speedKmh }
            ZoneSummary(
                zoneId = id,
                zoneName = name,
                total = ev.size,
                byClass = ev.groupingBy { it.cls }.eachCount(),
                byDirection = ev.groupingBy { it.direction }.eachCount(),
                avgSpeedKmh = if (speeds.isEmpty()) null else speeds.sum() / speeds.size,
                maxSpeedKmh = speeds.maxOrNull(),
            )
        }
    }

    /** One human-readable line per zone, shared by the UI and the PDF export. */
    fun line(s: ZoneSummary): String {
        val cls = s.byClass.entries.joinToString(", ") { "${it.key.label} ${it.value}" }
        val dir = s.byDirection.entries.joinToString(" ") { "${it.key}${it.value}" }
        val speed = if (s.avgSpeedKmh != null) {
            String.format(Locale.US, " | avg %.0f km/h, max %.0f km/h", s.avgSpeedKmh, s.maxSpeedKmh ?: 0f)
        } else ""
        return "${s.zoneName}: ${s.total}" + (if (cls.isNotEmpty()) " ($cls)" else "") +
            (if (dir.isNotEmpty()) " | $dir" else "") + speed
    }
}
