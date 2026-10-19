import Foundation

/// Counts tracks passing through user-defined zones and estimates their speed.
///
/// Like the reference app, a vehicle is counted as soon as its centre point enters a zone, once per zone and track,
/// provided it is moving (at least `minMove` of the frame height over the last `motionWindowMs`; parked vehicles are
/// never counted). If the zone has a `direction`, vehicles moving another way are ignored.
/// The event's arrow is the sign of the movement along the zone's long axis.
/// Speed is added to the event when the vehicle leaves the zone (or its track ends inside it) after travelling at
/// least `minProgress` of the zone length: zone length (m) * travelled fraction / time inside.
public final class ZoneCounter {
    private struct Key: Hashable {
        let zoneId: Int
        let trackId: Int
    }

    private struct InZone {
        let entryPos: Float
        let entryMs: Int64
        var lastPos: Float
        var lastMs: Int64
    }

    private struct Point {
        let x: Float
        let y: Float
        let t: Int64
    }

    private let minProgress: Float
    private let minMove: Float
    private let motionWindowMs: Int64
    private var states: [Key: InZone] = [:]
    /// Zone/track pairs already decided (counted -> event index, or rejected by the direction filter -> nil).
    private var decided: [Key: Int?] = [:]
    private var motion: [Int: [Point]] = [:]
    public private(set) var events: [CountEvent] = []

    public init(minProgress: Float = 0.25, minMove: Float = 0.02, motionWindowMs: Int64 = 1500) {
        self.minProgress = minProgress
        self.minMove = minMove
        self.motionWindowMs = motionWindowMs
    }

    public func reset() {
        states.removeAll()
        decided.removeAll()
        motion.removeAll()
        events.removeAll()
    }

    public static func isHorizontal(_ z: Zone, frameAspect: Float) -> Bool {
        z.rect.width * frameAspect >= z.rect.height
    }

    /// - Returns: the events produced (vehicles counted) by this update.
    @discardableResult
    public func update(zones: [Zone], frameAspect: Float, active: [Track], removed: [Track], tMs: Int64) -> [CountEvent] {
        var produced: [CountEvent] = []
        let zoneIds = Set(zones.map { $0.id })
        for key in states.keys where !zoneIds.contains(key.zoneId) { states.removeValue(forKey: key) }

        for t in active where t.lastSeenMs == tMs { // coasting tracks have no fresh position
            var pts = motion[t.id] ?? []
            pts.append(Point(x: t.box.cx, y: t.box.cy, t: tMs))
            pts.removeAll { tMs - $0.t > motionWindowMs }
            motion[t.id] = pts
            // movement in pixel-proportional units (x scaled by the frame aspect), relative to the frame height
            let dx = (pts[pts.count - 1].x - pts[0].x) * frameAspect
            let dy = pts[pts.count - 1].y - pts[0].y
            let moving = hypotf(dx, dy) >= minMove

            for z in zones {
                let key = Key(zoneId: z.id, trackId: t.id)
                let horizontal = Self.isHorizontal(z, frameAspect: frameAspect)
                if z.rect.contains(t.box.cx, t.box.cy) {
                    let pos = horizontal ? t.box.cx : t.box.cy
                    if var st = states[key] {
                        st.lastPos = pos
                        st.lastMs = tMs
                        states[key] = st
                    } else {
                        states[key] = InZone(entryPos: pos, entryMs: tMs, lastPos: pos, lastMs: tMs)
                    }
                    if decided[key] == nil && moving {
                        if let want = z.direction, !want.accepts(dx: dx, dy: dy) {
                            decided[key] = .some(nil)
                        } else {
                            let along = horizontal ? dx : dy
                            let arrow = horizontal ? (along >= 0 ? "→" : "←") : (along >= 0 ? "↓" : "↑")
                            let e = CountEvent(zoneId: z.id, zoneName: z.name, trackId: t.id, cls: t.cls, direction: arrow,
                                               speedKmh: nil, timeMs: tMs, score: t.score)
                            decided[key] = .some(events.count)
                            events.append(e)
                            produced.append(e)
                        }
                    }
                } else if let st = states.removeValue(forKey: key) {
                    addSpeed(z, horizontal, key, st)
                }
            }
        }

        for t in removed {
            for z in zones {
                let key = Key(zoneId: z.id, trackId: t.id)
                if let st = states.removeValue(forKey: key) {
                    addSpeed(z, Self.isHorizontal(z, frameAspect: frameAspect), key, st)
                }
                decided.removeValue(forKey: key)
            }
            motion.removeValue(forKey: t.id)
        }
        return produced
    }

    /// End of session: add the speed of vehicles still inside a zone.
    public func finish(zones: [Zone], frameAspect: Float) {
        for (key, st) in states {
            guard let z = zones.first(where: { $0.id == key.zoneId }) else { continue }
            addSpeed(z, Self.isHorizontal(z, frameAspect: frameAspect), key, st)
        }
        states.removeAll()
    }

    private func addSpeed(_ z: Zone, _ horizontal: Bool, _ key: Key, _ st: InZone) {
        guard let entry = decided[key], let index = entry, index < events.count else { return }
        let axisLen = horizontal ? z.rect.width : z.rect.height
        guard axisLen > 0, let len = z.lengthMeters, len > 0 else { return }
        let progress = abs(st.lastPos - st.entryPos) / axisLen
        let dtSec = Float(st.lastMs - st.entryMs) / 1000
        if progress >= minProgress && dtSec > 0.2 {
            events[index].speedKmh = len * progress / dtSec * 3.6
        }
    }
}
