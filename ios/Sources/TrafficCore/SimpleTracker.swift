import Foundation

public struct TrackerResult {
    /// Confirmed tracks that are still alive (including ones briefly not detected).
    public var active: [Track]
    /// Confirmed tracks dropped in this update.
    public var removed: [Track]

    public init(active: [Track], removed: [Track]) {
        self.active = active
        self.removed = removed
    }
}

/// Greedy IoU / centroid tracker with constant-velocity prediction and class voting.
/// Same algorithm as the Android app's SimpleTracker.
public final class SimpleTracker {
    private final class State {
        let id: Int
        var box: RectN
        var vx: Float
        var vy: Float
        let first: Int64
        var last: Int64
        var hits: Int
        var votes: [(VehicleClass, Float)]

        init(id: Int, box: RectN, first: Int64, cls: VehicleClass, score: Float) {
            self.id = id
            self.box = box
            self.vx = 0
            self.vy = 0
            self.first = first
            self.last = first
            self.hits = 1
            self.votes = [(cls, score)]
        }

        func vote(_ cls: VehicleClass, _ score: Float) {
            if let i = votes.firstIndex(where: { $0.0 == cls }) {
                votes[i].1 += score
            } else {
                votes.append((cls, score))
            }
        }

        func cls() -> VehicleClass {
            var best = votes[0]
            for v in votes.dropFirst() where v.1 > best.1 { best = v }
            return best.0
        }

        func snapshot() -> Track {
            Track(id: id, box: box, cls: cls(), hits: hits, firstSeenMs: first, lastSeenMs: last)
        }
    }

    private let maxAgeMs: Int64
    private let minHits: Int
    private var states: [State] = []
    private var nextId = 1

    public init(maxAgeMs: Int64 = 1200, minHits: Int = 2) {
        self.maxAgeMs = maxAgeMs
        self.minHits = minHits
    }

    public func reset() {
        states.removeAll()
        nextId = 1
    }

    public func update(_ detections: [Detection], tMs: Int64) -> TrackerResult {
        var candidates: [(cost: Float, i: Int, j: Int)] = []
        for (i, s) in states.enumerated() {
            let dt = Float(max(0, tMs - s.last))
            let predicted = s.box.shifted(s.vx * dt, s.vy * dt)
            for (j, d) in detections.enumerated() {
                let dist = hypotf(predicted.cx - d.box.cx, predicted.cy - d.box.cy)
                let size = max(max(s.box.width, s.box.height), max(d.box.width, d.box.height))
                let iou = predicted.iou(d.box)
                if iou >= 0.1 || dist <= 0.75 * size {
                    candidates.append((dist / size - iou, i, j))
                }
            }
        }
        candidates.sort { a, b in
            if a.cost != b.cost { return a.cost < b.cost }
            if a.i != b.i { return a.i < b.i }
            return a.j < b.j
        }

        var usedTracks = Set<Int>()
        var usedDets = Set<Int>()
        for c in candidates {
            if usedTracks.contains(c.i) || usedDets.contains(c.j) { continue }
            usedTracks.insert(c.i)
            usedDets.insert(c.j)
            let s = states[c.i]
            let d = detections[c.j]
            let dt = Float(tMs - s.last)
            if dt > 0 {
                s.vx = 0.5 * s.vx + 0.5 * (d.box.cx - s.box.cx) / dt
                s.vy = 0.5 * s.vy + 0.5 * (d.box.cy - s.box.cy) / dt
            }
            s.box = d.box
            s.last = tMs
            s.hits += 1
            s.vote(d.cls, d.score)
        }

        var removed: [Track] = []
        var survivors: [State] = []
        for (i, s) in states.enumerated() {
            if usedTracks.contains(i) || tMs - s.last <= maxAgeMs {
                survivors.append(s)
            } else if s.hits >= minHits {
                removed.append(s.snapshot())
            }
        }
        states = survivors

        for (j, d) in detections.enumerated() where !usedDets.contains(j) {
            states.append(State(id: nextId, box: d.box, first: tMs, cls: d.cls, score: d.score))
            nextId += 1
        }

        return TrackerResult(active: states.filter { $0.hits >= minHits }.map { $0.snapshot() }, removed: removed)
    }
}
