package com.freecount.traffic.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun carAt(cx: Float, cy: Float, size: Float = 0.05f, cls: VehicleClass = VehicleClass.CAR) =
    Detection(RectN(cx - size, cy - size, cx + size, cy + size), cls, 0.9f)

private fun trackAt(id: Int, cx: Float, cy: Float, tMs: Long, first: Long = 0L) =
    Track(id, RectN(cx - 0.02f, cy - 0.02f, cx + 0.02f, cy + 0.02f), VehicleClass.CAR, 5, first, tMs)

class SimpleTrackerTest {
    @Test
    fun movingObjectKeepsItsId() {
        val tracker = SimpleTracker()
        var id = -1
        for (i in 0 until 10) {
            val r = tracker.update(listOf(carAt(0.1f + 0.05f * i, 0.5f)), i * 100L)
            if (i >= 1) {
                assertEquals(1, r.active.size)
                if (id == -1) id = r.active[0].id
                assertEquals(id, r.active[0].id)
            }
        }
    }

    @Test
    fun twoObjectsGetDistinctIds() {
        val tracker = SimpleTracker()
        var last = TrackerResult(emptyList(), emptyList())
        for (i in 0 until 5) {
            last = tracker.update(
                listOf(carAt(0.2f + 0.02f * i, 0.3f), carAt(0.8f - 0.02f * i, 0.7f)),
                i * 100L,
            )
        }
        assertEquals(2, last.active.map { it.id }.toSet().size)
    }

    @Test
    fun staleTrackIsRemoved() {
        val tracker = SimpleTracker(maxAgeMs = 500)
        tracker.update(listOf(carAt(0.5f, 0.5f)), 0)
        tracker.update(listOf(carAt(0.5f, 0.5f)), 100)
        val r = tracker.update(emptyList(), 1000)
        assertEquals(1, r.removed.size)
        assertTrue(r.active.isEmpty())
    }

    @Test
    fun classIsChosenByVoting() {
        val tracker = SimpleTracker()
        tracker.update(listOf(carAt(0.5f, 0.5f, cls = VehicleClass.TRUCK)), 0)
        tracker.update(listOf(carAt(0.5f, 0.5f, cls = VehicleClass.CAR)), 100)
        val r = tracker.update(listOf(carAt(0.5f, 0.5f, cls = VehicleClass.TRUCK)), 200)
        assertEquals(VehicleClass.TRUCK, r.active[0].cls)
    }
}

class ZoneCounterTest {
    // Horizontal zone: x in [0.2, 0.8], y in [0.4, 0.6]; 30 m long.
    private val zone = Zone(1, "Lane", RectN(0.2f, 0.4f, 0.8f, 0.6f), lengthMeters = 30f)
    private val aspect = 16f / 9f

    @Test
    fun countsDirectionAndSpeed() {
        val counter = ZoneCounter()
        val frames = listOf(0.1f to 0L, 0.25f to 1000L, 0.75f to 2000L, 0.9f to 2200L)
        var produced = emptyList<CountEvent>()
        for ((x, t) in frames) {
            produced = produced + counter.update(listOf(zone), aspect, listOf(trackAt(7, x, 0.5f, t)), emptyList(), t)
        }
        assertEquals(1, produced.size)
        val e = produced[0]
        assertEquals("→", e.direction)
        assertEquals(7, e.trackId)
        // travelled (0.75-0.25)/0.6 = 0.833 of 30 m in 1 s = 25 m/s = 90 km/h
        assertEquals(90f, e.speedKmh!!, 1f)
    }

    @Test
    fun reverseDirection() {
        val counter = ZoneCounter()
        val frames = listOf(0.9f to 0L, 0.75f to 1000L, 0.25f to 2000L, 0.1f to 2200L)
        val produced = frames.flatMap { (x, t) ->
            counter.update(listOf(zone), aspect, listOf(trackAt(1, x, 0.5f, t)), emptyList(), t)
        }
        assertEquals("←", produced.single().direction)
    }

    @Test
    fun brushingTheZoneIsNotCounted() {
        val counter = ZoneCounter()
        val frames = listOf(0.1f to 0L, 0.22f to 1000L, 0.25f to 1500L, 0.1f to 2000L)
        val produced = frames.flatMap { (x, t) ->
            counter.update(listOf(zone), aspect, listOf(trackAt(1, x, 0.5f, t)), emptyList(), t)
        }
        assertTrue(produced.isEmpty())
    }

    @Test
    fun noSpeedWithoutZoneLength() {
        val counter = ZoneCounter()
        val noLength = zone.copy(lengthMeters = null)
        val frames = listOf(0.25f to 1000L, 0.75f to 2000L, 0.9f to 2200L)
        val produced = frames.flatMap { (x, t) ->
            counter.update(listOf(noLength), aspect, listOf(trackAt(1, x, 0.5f, t)), emptyList(), t)
        }
        assertNull(produced.single().speedKmh)
    }

    @Test
    fun trackEndingInsideIsFlushedWhenRemoved() {
        val counter = ZoneCounter()
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.25f, 0.5f, 0)), emptyList(), 0)
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.7f, 0.5f, 1000)), emptyList(), 1000)
        val produced = counter.update(listOf(zone), aspect, emptyList(), listOf(trackAt(3, 0.7f, 0.5f, 1000)), 3000)
        assertEquals(1, produced.size)
    }

    @Test
    fun finishFlushesVehiclesStillInside() {
        val counter = ZoneCounter()
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.25f, 0.5f, 0)), emptyList(), 0)
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.7f, 0.5f, 1000)), emptyList(), 1000)
        assertEquals(1, counter.finish(listOf(zone), aspect).size)
        assertEquals(1, counter.events.size)
    }

    @Test
    fun verticalZoneUsesVerticalArrows() {
        val vertical = Zone(2, "Up/down", RectN(0.4f, 0.1f, 0.6f, 0.9f), 20f)
        val counter = ZoneCounter()
        val frames = listOf(0.15f to 0L, 0.4f to 1000L, 0.8f to 2000L, 0.95f to 2200L)
        val produced = frames.flatMap { (y, t) ->
            counter.update(listOf(vertical), aspect, listOf(trackAt(1, 0.5f, y, t)), emptyList(), t)
        }
        assertEquals("↓", produced.single().direction)
    }
}

class SummaryAndCsvTest {
    private val events = listOf(
        CountEvent(1, "A", 1, VehicleClass.CAR, "→", 40f, 1000),
        CountEvent(1, "A", 2, VehicleClass.TRUCK, "←", 60f, 2000),
        CountEvent(1, "A", 3, VehicleClass.CAR, "→", null, 3000),
    )

    @Test
    fun summaryAggregates() {
        val s = Summary.of(events, listOf(Zone(1, "A", RectN(0f, 0f, 1f, 1f)), Zone(2, "B", RectN(0f, 0f, 1f, 1f))))
        assertEquals(2, s.size)
        assertEquals(3, s[0].total)
        assertEquals(2, s[0].byClass[VehicleClass.CAR])
        assertEquals(2, s[0].byDirection["→"])
        assertEquals(50f, s[0].avgSpeedKmh!!, 0.01f)
        assertEquals(60f, s[0].maxSpeedKmh!!, 0.01f)
        assertEquals(0, s[1].total)
        assertNull(s[1].avgSpeedKmh)
    }

    @Test
    fun csvHasHeaderRowsAndEscaping() {
        val csv = CsvExporter.build("Main, St", events)
        val lines = csv.trim().lines()
        assertEquals(4, lines.size)
        assertEquals("session,zone,track_id,class,direction,speed_kmh,time_s", lines[0])
        assertTrue(lines[1].startsWith("\"Main, St\",A,1,Car,→,40.0,1.00"))
        assertNotNull(lines[3])
        assertTrue(lines[3].contains(",3.00"))
    }
}
