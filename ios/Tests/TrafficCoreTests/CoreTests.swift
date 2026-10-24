import XCTest
@testable import TrafficCore

// Same cases as the Android app's CoreTest.kt, so both platforms agree on counting and speed.

private func carAt(_ cx: Float, _ cy: Float, size: Float = 0.05, cls: VehicleClass = .car) -> Detection {
    Detection(box: RectN(left: cx - size, top: cy - size, right: cx + size, bottom: cy + size), cls: cls, score: 0.9)
}

private func trackAt(_ id: Int, _ cx: Float, _ cy: Float, _ tMs: Int64) -> Track {
    Track(id: id, box: RectN(left: cx - 0.02, top: cy - 0.02, right: cx + 0.02, bottom: cy + 0.02),
          cls: .car, hits: 5, firstSeenMs: 0, lastSeenMs: tMs)
}

final class SimpleTrackerTests: XCTestCase {
    func testMovingObjectKeepsItsId() {
        let tracker = SimpleTracker()
        var id = -1
        for i in 0..<10 {
            let r = tracker.update([carAt(0.1 + 0.05 * Float(i), 0.5)], tMs: Int64(i) * 100)
            if i >= 1 {
                XCTAssertEqual(r.active.count, 1)
                if id == -1 { id = r.active[0].id }
                XCTAssertEqual(r.active[0].id, id)
            }
        }
    }

    func testTwoObjectsGetDistinctIds() {
        let tracker = SimpleTracker()
        var last = TrackerResult(active: [], removed: [])
        for i in 0..<5 {
            last = tracker.update([carAt(0.2 + 0.02 * Float(i), 0.3), carAt(0.8 - 0.02 * Float(i), 0.7)], tMs: Int64(i) * 100)
        }
        XCTAssertEqual(Set(last.active.map { $0.id }).count, 2)
    }

    func testStaleTrackIsRemoved() {
        let tracker = SimpleTracker(maxAgeMs: 500)
        _ = tracker.update([carAt(0.5, 0.5)], tMs: 0)
        _ = tracker.update([carAt(0.5, 0.5)], tMs: 100)
        let r = tracker.update([], tMs: 1000)
        XCTAssertEqual(r.removed.count, 1)
        XCTAssertTrue(r.active.isEmpty)
    }

    func testClassIsChosenByVoting() {
        let tracker = SimpleTracker()
        _ = tracker.update([carAt(0.5, 0.5, cls: .truck)], tMs: 0)
        _ = tracker.update([carAt(0.5, 0.5, cls: .car)], tMs: 100)
        let r = tracker.update([carAt(0.5, 0.5, cls: .truck)], tMs: 200)
        XCTAssertEqual(r.active[0].cls, .truck)
    }
}

final class ZoneCounterTests: XCTestCase {
    // Horizontal zone: x in [0.2, 0.8], y in [0.4, 0.6]; 30 m long.
    private let zone = Zone(id: 1, name: "Lane", rect: RectN(left: 0.2, top: 0.4, right: 0.8, bottom: 0.6), lengthMeters: 30)
    private let aspect: Float = 16.0 / 9.0

    private func run(_ counter: ZoneCounter, _ zone: Zone, _ frames: [(Float, Int64)], vertical: Bool = false, id: Int = 1) -> [CountEvent] {
        var out: [CountEvent] = []
        for (p, t) in frames {
            let tr = vertical ? trackAt(id, 0.5, p, t) : trackAt(id, p, 0.5, t)
            out += counter.update(zones: [zone], frameAspect: aspect, active: [tr], removed: [], tMs: t)
        }
        return out
    }

    func testCountsOnEntryThenAddsSpeedOnExit() {
        let counter = ZoneCounter()
        let produced = run(counter, zone, [(0.1, 0), (0.25, 1000), (0.75, 2000), (0.9, 2200)], id: 7)
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "→")
        XCTAssertEqual(produced[0].trackId, 7)
        XCTAssertEqual(produced[0].timeMs, 1000) // counted when it entered
        // travelled (0.75-0.25)/0.6 = 0.833 of 30 m in 1 s = 25 m/s = 90 km/h
        XCTAssertEqual(counter.events[0].speedKmh!, 90, accuracy: 1)
    }

    func testReverseDirection() {
        let produced = run(ZoneCounter(), zone, [(0.9, 0), (0.75, 1000), (0.25, 2000), (0.1, 2200)])
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "←")
    }

    func testEnteringBrieflyCountsButHasNoSpeed() {
        let counter = ZoneCounter()
        let produced = run(counter, zone, [(0.1, 0), (0.22, 1000), (0.25, 1500), (0.1, 2000)])
        XCTAssertEqual(produced.count, 1)
        XCTAssertNil(counter.events[0].speedKmh)
    }

    func testParkedVehicleIsNotCounted() {
        let produced = run(ZoneCounter(), zone, [(0.5, 0), (0.501, 1000), (0.499, 2000), (0.5, 3000)])
        XCTAssertTrue(produced.isEmpty)
    }

    func testReenteringTheSameZoneIsCountedOnce() {
        let produced = run(ZoneCounter(), zone, [(0.1, 0), (0.25, 500), (0.15, 1000), (0.3, 1500), (0.5, 2000)])
        XCTAssertEqual(produced.count, 1)
    }

    func testDirectionFilterIgnoresTheOtherWay() {
        var eastOnly = zone
        eastOnly.direction = .e
        XCTAssertEqual(run(ZoneCounter(), eastOnly, [(0.1, 0), (0.3, 1000), (0.5, 2000)]).count, 1)
        XCTAssertTrue(run(ZoneCounter(), eastOnly, [(0.9, 0), (0.7, 1000), (0.5, 2000)]).isEmpty)
    }

    func testHeadingAcceptsNearbyAngles() {
        XCTAssertTrue(Heading.s.accepts(dx: 0.3, dy: 1))   // mostly down, a bit right
        XCTAssertTrue(Heading.se.accepts(dx: 1, dy: 1))
        XCTAssertFalse(Heading.s.accepts(dx: 0, dy: -1))
        XCTAssertFalse(Heading.e.accepts(dx: -1, dy: 0.1))
        XCTAssertTrue(Heading.ne.accepts(dx: 1, dy: -1))
    }

    func testNoSpeedWithoutZoneLength() {
        var noLength = zone
        noLength.lengthMeters = nil
        let counter = ZoneCounter()
        let produced = run(counter, noLength, [(0.1, 0), (0.25, 1000), (0.75, 2000), (0.9, 2200)])
        XCTAssertEqual(produced.count, 1)
        XCTAssertNil(counter.events[0].speedKmh)
    }

    func testTrackEndingInsideGetsSpeedWhenRemoved() {
        let counter = ZoneCounter()
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.25, 0.5, 0)], removed: [], tMs: 0)
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.7, 0.5, 1000)], removed: [], tMs: 1000)
        XCTAssertEqual(counter.events.count, 1)
        counter.update(zones: [zone], frameAspect: aspect, active: [], removed: [trackAt(3, 0.7, 0.5, 1000)], tMs: 3000)
        XCTAssertEqual(counter.events.count, 1)
        XCTAssertNotNil(counter.events[0].speedKmh)
    }

    func testFinishAddsSpeedOfVehiclesStillInside() {
        let counter = ZoneCounter()
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.25, 0.5, 0)], removed: [], tMs: 0)
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.7, 0.5, 1000)], removed: [], tMs: 1000)
        counter.finish(zones: [zone], frameAspect: aspect)
        XCTAssertEqual(counter.events.count, 1)
        XCTAssertNotNil(counter.events[0].speedKmh)
    }

    func testVerticalZoneUsesVerticalArrows() {
        let vertical = Zone(id: 2, name: "Up/down", rect: RectN(left: 0.4, top: 0.1, right: 0.6, bottom: 0.9), lengthMeters: 20)
        let produced = run(ZoneCounter(), vertical, [(0.05, 0), (0.4, 1000), (0.8, 2000), (0.95, 2200)], vertical: true, id: 1)
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "↓")
    }

    func testRotatedZone() {
        // the horizontal lane box turned 90°: on screen it now runs top to bottom, ~0.11 of the width wide
        let turned = Zone(id: 3, name: "Turned", rect: zone.rect, lengthMeters: 30, angle: .pi / 2)
        XCTAssertTrue(turned.contains(0.5, 0.95, frameAspect: aspect))
        XCTAssertFalse(turned.contains(0.7, 0.5, frameAspect: aspect))
        XCTAssertTrue(zone.contains(0.7, 0.5, frameAspect: aspect))

        let counter = ZoneCounter()
        let produced = run(counter, turned, [(0.1, 0), (0.3, 1000), (0.5, 2000), (0.7, 3000), (0.9, 4000)], vertical: true)
        XCTAssertEqual(produced.count, 1)
        counter.finish(zones: [turned], frameAspect: aspect)
        // travelled 0.8 of the frame height = 0.75 of the box length (0.6 * 16/9 of the height) in 4 s
        XCTAssertEqual(counter.events[0].speedKmh ?? 0, 30 * 0.75 / 4 * 3.6, accuracy: 0.1)
    }
}

final class SummaryAndCsvTests: XCTestCase {
    private let events = [
        CountEvent(zoneId: 1, zoneName: "A", trackId: 1, cls: .car, direction: "→", speedKmh: 40, timeMs: 1000),
        CountEvent(zoneId: 1, zoneName: "A", trackId: 2, cls: .truck, direction: "←", speedKmh: 60, timeMs: 2000),
        CountEvent(zoneId: 1, zoneName: "A", trackId: 3, cls: .car, direction: "→", speedKmh: nil, timeMs: 3000),
    ]

    func testSummaryAggregates() {
        let zones = [Zone(id: 1, name: "A", rect: RectN(left: 0, top: 0, right: 1, bottom: 1)),
                     Zone(id: 2, name: "B", rect: RectN(left: 0, top: 0, right: 1, bottom: 1))]
        let s = Summary.of(events, zones: zones)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].total, 3)
        XCTAssertEqual(s[0].byClass[.car], 2)
        XCTAssertEqual(s[0].byDirection["→"], 2)
        XCTAssertEqual(s[0].avgSpeedKmh!, 50, accuracy: 0.01)
        XCTAssertEqual(s[0].maxSpeedKmh!, 60, accuracy: 0.01)
        XCTAssertEqual(s[1].total, 0)
        XCTAssertNil(s[1].avgSpeedKmh)
    }

    func testCsvHasHeaderRowsAndEscaping() {
        let csv = CsvExporter.build(sessionName: "Main, St", events: events)
        let lines = csv.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "session,zone,track_id,class,direction,speed_kmh,time_s,confidence,video_time,clock_time,category")
        XCTAssertTrue(lines[1].hasPrefix("\"Main, St\",A,1,Car,→,40.0,1.00"))
        XCTAssertTrue(lines[3].contains(",3.00"))
        XCTAssertTrue(lines[1].hasSuffix(",,,AUTOS/CAMIONETAS"))
        let video = CsvExporter.build(sessionName: "S", events: events, videoTimes: true)
        XCTAssertTrue(video.components(separatedBy: "\n")[1].hasSuffix(",0:01,,AUTOS/CAMIONETAS"))
    }

    func testVideoTime() {
        XCTAssertEqual(CsvExporter.videoTime(187_400), "3:07")
        XCTAssertEqual(CsvExporter.videoTime(3_787_000), "1:03:07")
    }

    func testUniqueCountsAVehicleInTwoBoxesOnce() {
        let two = events + [CountEvent(zoneId: 2, zoneName: "B", trackId: 1, cls: .car, direction: "→", speedKmh: nil, timeMs: 1500)]
        XCTAssertEqual(Summary.unique(two).count, 3)
        XCTAssertEqual(Summary.byClass(Summary.unique(two))[.car], 2)
    }

    private func at(_ minute: Int64, _ track: Int, _ cls: VehicleClass = .car) -> CountEvent {
        CountEvent(zoneId: 1, zoneName: "A", trackId: track, cls: cls, direction: "→", speedKmh: nil, timeMs: minute * 60_000)
    }

    func testIntervalsListEveryPeriod() {
        let ev = [at(1, 1), at(2, 2, .truck), at(31, 3)]
        let rows = Summary.intervals(ev, intervalMs: 15 * 60_000, durationMs: 45 * 60_000)
        XCTAssertEqual(rows.map { $0.total }, [2, 0, 1])
        XCTAssertEqual(rows[0].byClass[.truck], 1)
        XCTAssertEqual(rows[2].startMs, 30 * 60_000)
    }

    func testPeakHourAndPhf() {
        // 15-min volumes 10, 20, 30, 40, 5 -> peak hour = first four quarters (100 > 95), PHF = 100 / (4 * 40)
        var ev: [CountEvent] = []
        var id = 0
        for (q, n) in [10, 20, 30, 40, 5].enumerated() {
            for _ in 0..<n { id += 1; ev.append(at(Int64(q * 15 + 1), id)) }
        }
        let p = Summary.peakHour(ev, durationMs: 75 * 60_000)!
        XCTAssertEqual(p.startMs, 0)
        XCTAssertEqual(p.volume, 100)
        XCTAssertEqual(p.phf!, 100.0 / 160.0, accuracy: 0.001)
        XCTAssertNil(Summary.peakHour(ev, durationMs: 30 * 60_000))
    }

    func testIntervalsCsv() {
        let csv = CsvExporter.intervals(sessionName: "S", events: [at(1, 1), at(16, 2, .bus)],
                                        zones: [Zone(id: 1, name: "A", rect: RectN(left: 0, top: 0, right: 1, bottom: 1))],
                                        intervalMs: 15 * 60_000, durationMs: 30 * 60_000)
        let lines = csv.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "session,zone,interval_start,interval_end,car,truck,bus,motorcycle,bicycle,person,total")
        XCTAssertEqual(lines[1], "S,All boxes (unique),00:00:00,00:15:00,1,0,0,0,0,0,1")
        XCTAssertEqual(lines[4], "S,A,00:15:00,00:30:00,0,0,1,0,0,0,1")
        XCTAssertEqual(lines.count, 5)
    }
}

final class FichaTests: XCTestCase {
    private let zones = [Zone(id: 1, name: "A", rect: RectN(left: 0, top: 0, right: 1, bottom: 1)),
                         Zone(id: 2, name: "B", rect: RectN(left: 0, top: 0, right: 1, bottom: 1))]

    private func ev(_ minute: Int64, _ track: Int, _ cls: VehicleClass = .car, zone: Int = 1, dir: String = "↓",
                    axle: AxleClass? = nil) -> CountEvent {
        CountEvent(zoneId: zone, zoneName: zone == 1 ? "A" : "B", trackId: track, cls: cls, direction: dir,
                   speedKmh: nil, timeMs: minute * 60_000, axle: axle)
    }

    func testCategories() {
        XCTAssertEqual(FichaCategory(ev(0, 1)), .autos)
        XCTAssertEqual(FichaCategory(ev(0, 1, .truck)), .sinClasificar)
        XCTAssertEqual(FichaCategory(ev(0, 1, .truck, axle: .c34)), .c34)
        XCTAssertEqual(FichaCategory(ev(0, 1, .bus)), .bus)
        XCTAssertNil(FichaCategory(ev(0, 1, .person)))
    }

    func testPeriodsFollowTheClock() {
        // session starts at 07:10 and lasts 25 min: periods 07:00-07:15 (partial), 07:15-07:30, 07:30-07:45 (partial)
        let start: Int64 = (7 * 60 + 10) * 60_000
        let t = Ficha.table([ev(2, 1), ev(6, 2, .truck, axle: .c5), ev(21, 3, .truck), ev(3, 4, zone: 2, dir: "↑")],
                            zones: zones, durationMs: 25 * 60_000, dayOffsetMs: start)
        XCTAssertEqual(t.periods.map { $0.startOfDayMs / 60_000 }, [420, 435, 450])
        XCTAssertEqual(t.periods.map { $0.partial }, [true, false, true])
        XCTAssertEqual(t.movements, ["A ↓", "B ↑"])
        XCTAssertEqual(t.counts[0][0][.autos], 1)         // 07:12
        XCTAssertEqual(t.counts[0][1][.c5], 1)            // 07:16
        XCTAssertEqual(t.counts[0][2][.sinClasificar], 1) // 07:31
        XCTAssertEqual(t.total(movement: 1, .autos), 1)
    }

    func testEmptyBoxStillGetsASheet() {
        let t = Ficha.table([ev(1, 1)], zones: zones, durationMs: 10 * 60_000, dayOffsetMs: 0)
        XCTAssertEqual(t.movements, ["A ↓", "B"])
        XCTAssertEqual(t.periods.count, 1)
    }
}
