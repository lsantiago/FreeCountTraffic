package com.freecount.traffic.core

import java.util.Locale

object CsvExporter {
    private fun esc(s: String): String =
        if (s.any { it == ',' || it == '"' || it == '\n' }) "\"" + s.replace("\"", "\"\"") + "\"" else s

    fun build(sessionName: String, events: List<CountEvent>): String {
        val sb = StringBuilder("session,zone,track_id,class,direction,speed_kmh,time_s\n")
        for (e in events) {
            sb.append(esc(sessionName)).append(',')
                .append(esc(e.zoneName)).append(',')
                .append(e.trackId).append(',')
                .append(e.cls.label).append(',')
                .append(e.direction).append(',')
                .append(e.speedKmh?.let { String.format(Locale.US, "%.1f", it) } ?: "").append(',')
                .append(String.format(Locale.US, "%.2f", e.timeMs / 1000.0))
                .append('\n')
        }
        return sb.toString()
    }
}
