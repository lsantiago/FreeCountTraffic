package com.freecount.traffic.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.Summary
import com.freecount.traffic.core.VehicleClass
import com.freecount.traffic.core.Zone
import com.freecount.traffic.core.ZoneSummary
import java.util.Locale

@Composable
fun Swatch(color: Color, modifier: Modifier = Modifier, size: Int = 18) {
    Box(modifier.size(size.dp).background(color, RoundedCornerShape(5.dp)))
}

/** "● CAR ........ 94" row used inside summary cards. */
@Composable
fun ClassRow(cls: VehicleClass, count: Int) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Swatch(Palette.cls(cls), size = 14)
        Spacer(Modifier.width(10.dp))
        Text(cls.label.uppercase(Locale.US), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(count.toString(), style = MaterialTheme.typography.bodyMedium)
    }
}

/** Compact "● 94  ● 3" chips for the live per-box list. */
@Composable
fun ClassChips(byClass: Map<VehicleClass, Int>) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        VehicleClass.entries.forEach { c ->
            val n = byClass[c] ?: return@forEach
            Row(verticalAlignment = Alignment.CenterVertically) {
                Swatch(Palette.cls(c), size = 10)
                Spacer(Modifier.width(4.dp))
                Text(n.toString(), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
fun SummaryCard(total: Int, byClass: Map<VehicleClass, Int>) {
    Column(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(16.dp)).padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Total Unique Vehicles Tracked", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            Text(total.toString(), style = MaterialTheme.typography.headlineMedium)
        }
        Spacer(Modifier.height(6.dp))
        VehicleClass.entries.forEach { c -> byClass[c]?.let { ClassRow(c, it) } }
    }
}

@Composable
fun ZoneSection(index: Int, s: ZoneSummary) {
    Column(Modifier.fillMaxWidth().padding(top = 18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Swatch(Palette.zone(index))
            Spacer(Modifier.width(10.dp))
            Text(s.zoneName, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            Text("${s.total} vehicles", style = MaterialTheme.typography.bodyMedium)
        }
        Column(Modifier.padding(start = 28.dp, top = 6.dp)) {
            VehicleClass.entries.forEach { c -> s.byClass[c]?.let { ClassRow(c, it) } }
            if (s.byDirection.isNotEmpty()) {
                Text(
                    "Direction: " + s.byDirection.entries.joinToString("   ") { "${it.key} ${it.value}" },
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            if (s.avgSpeedKmh != null) {
                Text(
                    String.format(Locale.US, "Speed: avg %.0f km/h · max %.0f km/h", s.avgSpeedKmh, s.maxSpeedKmh ?: 0f),
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

/** Total card followed by one section per zone. */
@Composable
fun ResultsPanel(events: List<CountEvent>, zones: List<Zone>) {
    val byClass = events.groupingBy { it.cls }.eachCount()
    Column(Modifier.fillMaxWidth()) {
        SummaryCard(events.size, byClass)
        Summary.of(events, zones).forEachIndexed { i, s -> ZoneSection(i, s) }
    }
}
