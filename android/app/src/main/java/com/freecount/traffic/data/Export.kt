package com.freecount.traffic.data

import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.CsvExporter
import com.freecount.traffic.core.Heading
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.Summary
import com.freecount.traffic.core.VehicleClass
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
                    .put("len", z.lengthMeters?.toDouble() ?: JSONObject.NULL)
                    .put("dir", z.direction?.name ?: JSONObject.NULL),
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
                if (!o.has("dir") || o.isNull("dir")) null else runCatching { Heading.valueOf(o.getString("dir")) }.getOrNull(),
            )
        }
    }.getOrDefault(emptyList())
}

/** Small images of the counted vehicles (for Validate Detections): filesDir/thumbs/<session id>/<track id>.jpg. */
object ThumbStore {
    private fun dir(context: Context, sessionId: Long) = File(context.filesDir, "thumbs/$sessionId")

    fun save(context: Context, sessionId: Long, thumbs: Map<Int, ByteArray>) {
        if (thumbs.isEmpty()) return
        val d = dir(context, sessionId).apply { mkdirs() }
        thumbs.forEach { (track, jpeg) -> File(d, "$track.jpg").writeBytes(jpeg) }
    }

    fun file(context: Context, sessionId: Long, trackId: Int): File? =
        File(dir(context, sessionId), "$trackId.jpg").takeIf { it.exists() }

    fun delete(context: Context, sessionId: Long) {
        dir(context, sessionId).deleteRecursively()
    }
}

object Exporter {
    const val QUARTER_MS = 15 * 60 * 1000L

    private fun exportFile(context: Context, name: String): File {
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        return File(dir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
    }

    /** Two files: every counted vehicle, and the 15-minute volume table. */
    fun csv(context: Context, session: SessionEntity, events: List<CountEvent>): List<File> = listOf(
        exportFile(context, "${session.name}.csv").also { it.writeText(CsvExporter.build(session.name, events)) },
        exportFile(context, "${session.name}_15min.csv").also {
            it.writeText(
                CsvExporter.intervals(
                    session.name, events, ZoneJson.decode(session.zonesJson), QUARTER_MS, session.durationMs, session.clockStart,
                ),
            )
        },
    )

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
        line("Duration: ${CsvExporter.clock(session.durationMs)}")
        if (session.latitude != null && session.longitude != null) {
            line(String.format(Locale.US, "Location: %.5f, %.5f", session.latitude, session.longitude))
        }
        y += 8f
        line("Summary", title, 24f)
        val unique = Summary.unique(events)
        val cls = VehicleClass.entries.mapNotNull { c -> Summary.byClass(unique)[c]?.let { "${c.label} $it" } }.joinToString(", ")
        line("Unique vehicles: ${unique.size}" + if (cls.isEmpty()) "" else " ($cls)")
        Summary.of(events, ZoneJson.decode(session.zonesJson)).forEach { line(Summary.line(it)) }
        Summary.peakHour(events, session.durationMs)?.let { p ->
            val phf = p.phf?.let { String.format(Locale.US, ", PHF %.2f", it) } ?: ""
            line(
                "Peak hour: ${CsvExporter.clock(p.startMs, session.clockStart)}-" +
                    "${CsvExporter.clock(p.startMs + 4 * QUARTER_MS, session.clockStart)}, ${p.volume} vehicles$phf",
            )
        }
        y += 8f
        line("15-minute volumes (unique vehicles)", title, 24f)
        line("interval  " + VehicleClass.entries.joinToString("  ") { it.label } + "  total")
        Summary.intervals(events, QUARTER_MS, session.durationMs).forEach { r ->
            line(
                CsvExporter.clock(r.startMs, session.clockStart) + "  " +
                    VehicleClass.entries.joinToString("  ") { (r.byClass[it] ?: 0).toString() } + "  " + r.total,
            )
        }
        y += 8f
        line("Vehicles", title, 24f)
        line("time  zone  class  direction  speed(km/h)  confidence")
        events.forEach {
            val speed = it.speedKmh?.let { s -> String.format(Locale.US, "%.0f", s) } ?: "-"
            val conf = it.score?.let { s -> String.format(Locale.US, "%.0f%%", s * 100) } ?: "-"
            line("${CsvExporter.clock(it.timeMs, session.clockStart)}  ${it.zoneName}  ${it.cls.label}  ${it.direction}  $speed  $conf")
        }
        doc.finishPage(page)

        val file = exportFile(context, "${session.name}.pdf")
        file.outputStream().use { doc.writeTo(it) }
        doc.close()
        return file
    }

    fun share(context: Context, files: List<File>, mime: String) {
        val uris = ArrayList(files.map { FileProvider.getUriForFile(context, "${context.packageName}.files", it) })
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }.apply {
            type = mime
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
