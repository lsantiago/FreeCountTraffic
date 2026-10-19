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

object Summary {
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
