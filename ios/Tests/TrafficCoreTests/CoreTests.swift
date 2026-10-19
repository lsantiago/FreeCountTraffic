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

    func testCountsDirectionAndSpeed() {
        let produced = run(ZoneCounter(), zone, [(0.1, 0), (0.25, 1000), (0.75, 2000), (0.9, 2200)], id: 7)
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "→")
        XCTAssertEqual(produced[0].trackId, 7)
        // travelled (0.75-0.25)/0.6 = 0.833 of 30 m in 1 s = 25 m/s = 90 km/h
        XCTAssertEqual(produced[0].speedKmh!, 90, accuracy: 1)
    }

    func testReverseDirection() {
        let produced = run(ZoneCounter(), zone, [(0.9, 0), (0.75, 1000), (0.25, 2000), (0.1, 2200)])
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "←")
    }

    func testBrushingTheZoneIsNotCounted() {
        let produced = run(ZoneCounter(), zone, [(0.1, 0), (0.22, 1000), (0.25, 1500), (0.1, 2000)])
        XCTAssertTrue(produced.isEmpty)
    }

    func testNoSpeedWithoutZoneLength() {
        var noLength = zone
        noLength.lengthMeters = nil
        let produced = run(ZoneCounter(), noLength, [(0.25, 1000), (0.75, 2000), (0.9, 2200)])
        XCTAssertEqual(produced.count, 1)
        XCTAssertNil(produced[0].speedKmh)
    }

    func testTrackEndingInsideIsFlushedWhenRemoved() {
        let counter = ZoneCounter()
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.25, 0.5, 0)], removed: [], tMs: 0)
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.7, 0.5, 1000)], removed: [], tMs: 1000)
        let produced = counter.update(zones: [zone], frameAspect: aspect, active: [], removed: [trackAt(3, 0.7, 0.5, 1000)], tMs: 3000)
        XCTAssertEqual(produced.count, 1)
    }

    func testFinishFlushesVehiclesStillInside() {
        let counter = ZoneCounter()
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.25, 0.5, 0)], removed: [], tMs: 0)
        counter.update(zones: [zone], frameAspect: aspect, active: [trackAt(3, 0.7, 0.5, 1000)], removed: [], tMs: 1000)
        XCTAssertEqual(counter.finish(zones: [zone], frameAspect: aspect).count, 1)
        XCTAssertEqual(counter.events.count, 1)
    }

    func testVerticalZoneUsesVerticalArrows() {
        let vertical = Zone(id: 2, name: "Up/down", rect: RectN(left: 0.4, top: 0.1, right: 0.6, bottom: 0.9), lengthMeters: 20)
        let produced = run(ZoneCounter(), vertical, [(0.15, 0), (0.4, 1000), (0.8, 2000), (0.95, 2200)], vertical: true, id: 1)
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].direction, "↓")
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
        XCTAssertEqual(lines[0], "session,zone,track_id,class,direction,speed_kmh,time_s")
        XCTAssertTrue(lines[1].hasPrefix("\"Main, St\",A,1,Car,→,40.0,1.00"))
        XCTAssertTrue(lines[3].contains(",3.00"))
    }
}
