import Foundation

/// Counts tracks passing through user-defined zones and estimates their speed.
///
/// A vehicle is counted when it leaves a zone (or its track ends inside it) after having travelled at least
/// `minProgress` of the zone length along the zone's long axis. Direction is the sign of that travel.
/// Speed = zone length (m) * travelled fraction / time inside, so `Zone.lengthMeters` must be set for speed.
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
        var cls: VehicleClass
    }

    private let minProgress: Float
    private var states: [Key: InZone] = [:]
    public private(set) var events: [CountEvent] = []

    public init(minProgress: Float = 0.25) {
        self.minProgress = minProgress
    }

    public func reset() {
        states.removeAll()
        events.removeAll()
    }

    public static func isHorizontal(_ z: Zone, frameAspect: Float) -> Bool {
        z.rect.width * frameAspect >= z.rect.height
    }

    /// - Returns: the events produced by this update.
    @discardableResult
    public func update(zones: [Zone], frameAspect: Float, active: [Track], removed: [Track], tMs: Int64) -> [CountEvent] {
        var produced: [CountEvent] = []
        let zoneIds = Set(zones.map { $0.id })
        for key in states.keys where !zoneIds.contains(key.zoneId) { states.removeValue(forKey: key) }

        for z in zones {
            let horizontal = Self.isHorizontal(z, frameAspect: frameAspect)
            for t in active {
                if t.lastSeenMs != tMs { continue } // coasting, no fresh position
                let key = Key(zoneId: z.id, trackId: t.id)
                let inside = z.rect.contains(t.box.cx, t.box.cy)
                if inside {
                    let pos = horizontal ? t.box.cx : t.box.cy
                    if var st = states[key] {
                        st.lastPos = pos
                        st.lastMs = tMs
                        st.cls = t.cls
                        states[key] = st
                    } else {
                        states[key] = InZone(entryPos: pos, entryMs: tMs, lastPos: pos, lastMs: tMs, cls: t.cls)
                    }
                } else if let st = states[key] {
                    if let e = finish(z, horizontal, t.id, st) { produced.append(e) }
                    states.removeValue(forKey: key)
                }
            }
        }

        for t in removed {
            for z in zones {
                let key = Key(zoneId: z.id, trackId: t.id)
                guard let st = states.removeValue(forKey: key) else { continue }
                if let e = finish(z, Self.isHorizontal(z, frameAspect: frameAspect), t.id, st) { produced.append(e) }
            }
        }
        events.append(contentsOf: produced)
        return produced
    }

    /// Flush vehicles still inside a zone (end of session).
    @discardableResult
    public func finish(zones: [Zone], frameAspect: Float) -> [CountEvent] {
        var produced: [CountEvent] = []
        for (key, st) in states {
            guard let z = zones.first(where: { $0.id == key.zoneId }) else { continue }
            if let e = finish(z, Self.isHorizontal(z, frameAspect: frameAspect), key.trackId, st) { produced.append(e) }
        }
        states.removeAll()
        events.append(contentsOf: produced)
        return produced
    }

    private func finish(_ z: Zone, _ horizontal: Bool, _ trackId: Int, _ st: InZone) -> CountEvent? {
        let axisLen = horizontal ? z.rect.width : z.rect.height
        if axisLen <= 0 { return nil }
        let progress = (st.lastPos - st.entryPos) / axisLen
        if abs(progress) < minProgress { return nil }
        let forward = progress > 0
        let arrow = horizontal ? (forward ? "→" : "←") : (forward ? "↓" : "↑")
        let dtSec = Float(st.lastMs - st.entryMs) / 1000
        var speed: Float?
        if let len = z.lengthMeters, len > 0, dtSec > 0.2 {
            speed = len * abs(progress) / dtSec * 3.6
        }
        return CountEvent(zoneId: z.id, zoneName: z.name, trackId: trackId, cls: st.cls, direction: arrow, speedKmh: speed, timeMs: st.lastMs)
    }
}
