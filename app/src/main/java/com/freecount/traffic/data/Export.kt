package com.freecount.traffic.data

import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.CsvExporter
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.Summary
import com.freecount.traffic.core.Zone
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

object ZoneJson {
    fun encode(zones: List<Zone>): String = JSONArray().also { arr ->
        zones.forEach { z ->
            arr.put(
                JSONObject()
                    .put("id", z.id).put("name", z.name)
                    .put("l", z.rect.left.toDouble()).put("t", z.rect.top.toDouble())
                    .put("r", z.rect.right.toDouble()).put("b", z.rect.bottom.toDouble())
                    .put("len", z.lengthMeters?.toDouble() ?: JSONObject.NULL),
            )
        }
    }.toString()

    fun decode(json: String): List<Zone> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Zone(
                o.getInt("id"), o.getString("name"),
                RectN(o.getDouble("l").toFloat(), o.getDouble("t").toFloat(), o.getDouble("r").toFloat(), o.getDouble("b").toFloat()),
                if (o.isNull("len")) null else o.getDouble("len").toFloat(),
            )
        }
    }.getOrDefault(emptyList())
}

object Exporter {
    private fun exportFile(context: Context, name: String): File {
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        return File(dir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
    }

    fun csv(context: Context, session: SessionEntity, events: List<CountEvent>): File =
        exportFile(context, "${session.name}.csv").also { it.writeText(CsvExporter.build(session.name, events)) }

    fun pdf(context: Context, session: SessionEntity, events: List<CountEvent>): File {
        val doc = PdfDocument()
        val title = Paint().apply { textSize = 18f; isFakeBoldText = true }
        val body = Paint().apply { textSize = 11f }
        val pageW = 595
        val pageH = 842
        val margin = 40f

        var pageNo = 1
        var page = doc.startPage(PdfDocument.PageInfo.Builder(pageW, pageH, pageNo).create())
        var y = margin

        fun line(text: String, paint: Paint = body, gap: Float = 16f) {
            if (y > pageH - margin) {
                doc.finishPage(page)
                pageNo++
                page = doc.startPage(PdfDocument.PageInfo.Builder(pageW, pageH, pageNo).create())
                y = margin
            }
            page.canvas.drawText(text, margin, y, paint)
            y += gap
        }

        line("Traffic count - ${session.name}", title, 26f)
        line("Started: ${DateFormat.getDateTimeInstance().format(Date(session.startedAt))}   Source: ${session.source}")
        line("Duration: ${session.durationMs / 1000} s")
        if (session.latitude != null && session.longitude != null) {
            line(String.format(Locale.US, "Location: %.5f, %.5f", session.latitude, session.longitude))
        }
        y += 8f
        line("Summary", title, 24f)
        Summary.of(events, ZoneJson.decode(session.zonesJson)).forEach { line(Summary.line(it)) }
        y += 8f
        line("Vehicles", title, 24f)
        line("time(s)  zone  class  direction  speed(km/h)")
        events.forEach {
            val speed = it.speedKmh?.let { s -> String.format(Locale.US, "%.0f", s) } ?: "-"
            line(String.format(Locale.US, "%.1f  %s  %s  %s  %s", it.timeMs / 1000.0, it.zoneName, it.cls.label, it.direction, speed))
        }
        doc.finishPage(page)

        val file = exportFile(context, "${session.name}.pdf")
        file.outputStream().use { doc.writeTo(it) }
        doc.close()
        return file
    }

    fun share(context: Context, file: File, mime: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
