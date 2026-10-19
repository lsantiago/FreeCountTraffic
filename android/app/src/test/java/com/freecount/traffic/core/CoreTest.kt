package com.freecount.traffic.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    private fun run(counter: ZoneCounter, z: Zone, frames: List<Pair<Float, Long>>, vertical: Boolean = false, id: Int = 1) =
        frames.flatMap { (p, t) ->
            val tr = if (vertical) trackAt(id, 0.5f, p, t) else trackAt(id, p, 0.5f, t)
            counter.update(listOf(z), aspect, listOf(tr), emptyList(), t)
        }

    @Test
    fun countsOnEntryThenAddsSpeedOnExit() {
        val counter = ZoneCounter()
        val produced = run(counter, zone, listOf(0.1f to 0L, 0.25f to 1000L, 0.75f to 2000L, 0.9f to 2200L), id = 7)
        assertEquals(1, produced.size)
        assertEquals("→", produced[0].direction)
        assertEquals(7, produced[0].trackId)
        assertEquals(1000L, produced[0].timeMs) // counted when it entered
        // travelled (0.75-0.25)/0.6 = 0.833 of 30 m in 1 s = 25 m/s = 90 km/h
        assertEquals(90f, counter.events[0].speedKmh!!, 1f)
    }

    @Test
    fun reverseDirection() {
        val produced = run(ZoneCounter(), zone, listOf(0.9f to 0L, 0.75f to 1000L, 0.25f to 2000L, 0.1f to 2200L))
        assertEquals("←", produced.single().direction)
    }

    @Test
    fun enteringBrieflyCountsButHasNoSpeed() {
        val counter = ZoneCounter()
        val produced = run(counter, zone, listOf(0.1f to 0L, 0.22f to 1000L, 0.25f to 1500L, 0.1f to 2000L))
        assertEquals(1, produced.size)
        assertNull(counter.events[0].speedKmh)
    }

    @Test
    fun parkedVehicleIsNotCounted() {
        val produced = run(ZoneCounter(), zone, listOf(0.5f to 0L, 0.501f to 1000L, 0.499f to 2000L, 0.5f to 3000L))
        assertTrue(produced.isEmpty())
    }

    @Test
    fun reenteringTheSameZoneIsCountedOnce() {
        val produced = run(ZoneCounter(), zone, listOf(0.1f to 0L, 0.25f to 500L, 0.15f to 1000L, 0.3f to 1500L, 0.5f to 2000L))
        assertEquals(1, produced.size)
    }

    @Test
    fun directionFilterIgnoresTheOtherWay() {
        val eastOnly = zone.copy(direction = Heading.E)
        assertEquals(1, run(ZoneCounter(), eastOnly, listOf(0.1f to 0L, 0.3f to 1000L, 0.5f to 2000L)).size)
        assertTrue(run(ZoneCounter(), eastOnly, listOf(0.9f to 0L, 0.7f to 1000L, 0.5f to 2000L)).isEmpty())
    }

    @Test
    fun headingAcceptsNearbyAngles() {
        assertTrue(Heading.S.accepts(0.3f, 1f))
        assertTrue(Heading.SE.accepts(1f, 1f))
        assertFalse(Heading.S.accepts(0f, -1f))
        assertFalse(Heading.E.accepts(-1f, 0.1f))
        assertTrue(Heading.NE.accepts(1f, -1f))
    }

    @Test
    fun noSpeedWithoutZoneLength() {
        val counter = ZoneCounter()
        val produced = run(counter, zone.copy(lengthMeters = null), listOf(0.1f to 0L, 0.25f to 1000L, 0.75f to 2000L, 0.9f to 2200L))
        assertEquals(1, produced.size)
        assertNull(counter.events[0].speedKmh)
    }

    @Test
    fun trackEndingInsideGetsSpeedWhenRemoved() {
        val counter = ZoneCounter()
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.25f, 0.5f, 0)), emptyList(), 0)
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.7f, 0.5f, 1000)), emptyList(), 1000)
        assertEquals(1, counter.events.size)
        counter.update(listOf(zone), aspect, emptyList(), listOf(trackAt(3, 0.7f, 0.5f, 1000)), 3000)
        assertEquals(1, counter.events.size)
        assertNotNull(counter.events[0].speedKmh)
    }

    @Test
    fun finishAddsSpeedOfVehiclesStillInside() {
        val counter = ZoneCounter()
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.25f, 0.5f, 0)), emptyList(), 0)
        counter.update(listOf(zone), aspect, listOf(trackAt(3, 0.7f, 0.5f, 1000)), emptyList(), 1000)
        counter.finish(listOf(zone), aspect)
        assertEquals(1, counter.events.size)
        assertNotNull(counter.events[0].speedKmh)
    }

    @Test
    fun verticalZoneUsesVerticalArrows() {
        val vertical = Zone(2, "Up/down", RectN(0.4f, 0.1f, 0.6f, 0.9f), 20f)
        val produced = run(ZoneCounter(), vertical, listOf(0.05f to 0L, 0.4f to 1000L, 0.8f to 2000L, 0.95f to 2200L), vertical = true)
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
        assertEquals("session,zone,track_id,class,direction,speed_kmh,time_s,confidence", lines[0])
        assertTrue(lines[1].startsWith("\"Main, St\",A,1,Car,→,40.0,1.00"))
        assertNotNull(lines[3])
        assertTrue(lines[3].contains(",3.00"))
    }

    @Test
    fun uniqueCountsAVehicleInTwoBoxesOnce() {
        val two = events + CountEvent(2, "B", 1, VehicleClass.CAR, "→", null, 1500)
        assertEquals(3, Summary.unique(two).size)
        assertEquals(2, Summary.byClass(Summary.unique(two))[VehicleClass.CAR])
    }

    private fun at(minute: Long, track: Int, cls: VehicleClass = VehicleClass.CAR) =
        CountEvent(1, "A", track, cls, "→", null, minute * 60_000)

    @Test
    fun intervalsListEveryPeriod() {
        val rows = Summary.intervals(listOf(at(1, 1), at(2, 2, VehicleClass.TRUCK), at(31, 3)), 15 * 60_000L, 45 * 60_000L)
        assertEquals(listOf(2, 0, 1), rows.map { it.total })
        assertEquals(1, rows[0].byClass[VehicleClass.TRUCK])
        assertEquals(30 * 60_000L, rows[2].startMs)
    }

    @Test
    fun peakHourAndPhf() {
        // 15-min volumes 10, 20, 30, 40, 5 -> peak hour = first four quarters (100 > 95), PHF = 100 / (4 * 40)
        val ev = mutableListOf<CountEvent>()
        var id = 0
        listOf(10, 20, 30, 40, 5).forEachIndexed { q, n -> repeat(n) { ev += at(q * 15L + 1, ++id) } }
        val p = Summary.peakHour(ev, 75 * 60_000L)!!
        assertEquals(0L, p.startMs)
        assertEquals(100, p.volume)
        assertEquals(100f / 160f, p.phf!!, 0.001f)
        assertNull(Summary.peakHour(ev, 30 * 60_000L))
    }

    @Test
    fun intervalsCsv() {
        val csv = CsvExporter.intervals(
            "S", listOf(at(1, 1), at(16, 2, VehicleClass.BUS)), listOf(Zone(1, "A", RectN(0f, 0f, 1f, 1f))),
            15 * 60_000L, 30 * 60_000L,
        )
        val lines = csv.trim().lines()
        assertEquals("session,zone,interval_start,interval_end,car,truck,bus,motorcycle,bicycle,person,total", lines[0])
        assertEquals("S,All boxes (unique),00:00:00,00:15:00,1,0,0,0,0,0,1", lines[1])
        assertEquals("S,A,00:15:00,00:30:00,0,0,1,0,0,0,1", lines[4])
        assertEquals(5, lines.size)
    }
}
