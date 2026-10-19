package com.freecount.traffic.core

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object CsvExporter {
    private fun esc(s: String): String =
        if (s.any { it == ',' || it == '"' || it == '\n' }) "\"" + s.replace("\"", "\"\"") + "\"" else s

    fun build(sessionName: String, events: List<CountEvent>): String {
        val sb = StringBuilder("session,zone,track_id,class,direction,speed_kmh,time_s,confidence\n")
        for (e in events) {
            sb.append(esc(sessionName)).append(',')
                .append(esc(e.zoneName)).append(',')
                .append(e.trackId).append(',')
                .append(e.cls.label).append(',')
                .append(e.direction).append(',')
                .append(e.speedKmh?.let { String.format(Locale.US, "%.1f", it) } ?: "").append(',')
                .append(String.format(Locale.US, "%.2f", e.timeMs / 1000.0)).append(',')
                .append(e.score?.let { String.format(Locale.US, "%.2f", it) } ?: "")
                .append('\n')
        }
        return sb.toString()
    }

    /** "hh:mm:ss" from the start of the session, or the wall-clock time when [startEpochMs] is given. */
    fun clock(ms: Long, startEpochMs: Long? = null): String {
        if (startEpochMs != null) return SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(startEpochMs + ms))
        val s = ms / 1000
        return String.format(Locale.US, "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /** Volume table for traffic studies: one row per interval for all boxes (unique vehicles) and for each box. */
    fun intervals(
        sessionName: String,
        events: List<CountEvent>,
        zones: List<Zone>,
        intervalMs: Long,
        durationMs: Long,
        startEpochMs: Long? = null,
    ): String {
        val classes = VehicleClass.entries
        val sb = StringBuilder("session,zone,interval_start,interval_end,")
            .append(classes.joinToString(",") { it.name.lowercase() }).append(",total\n")
        val groups = listOf<Pair<String, Int?>>("All boxes (unique)" to null) +
            Summary.of(events, zones).map { it.zoneName to it.zoneId }
        for ((name, id) in groups) {
            for (r in Summary.intervals(events, intervalMs, durationMs, id)) {
                sb.append(esc(sessionName)).append(',').append(esc(name)).append(',')
                    .append(clock(r.startMs, startEpochMs)).append(',').append(clock(r.endMs, startEpochMs)).append(',')
                    .append(classes.joinToString(",") { (r.byClass[it] ?: 0).toString() })
                    .append(',').append(r.total).append('\n')
            }
        }
        return sb.toString()
    }
}
