import Foundation

public struct ZoneSummary {
    public var zoneId: Int
    public var zoneName: String
    public var total: Int
    public var byClass: [VehicleClass: Int]
    public var byDirection: [String: Int]
    public var avgSpeedKmh: Float?
    public var maxSpeedKmh: Float?
}

public struct IntervalRow: Equatable {
    public var startMs: Int64
    public var endMs: Int64
    public var byClass: [VehicleClass: Int]
    public var total: Int { byClass.values.reduce(0, +) }
}

public struct PeakHour: Equatable {
    public var startMs: Int64
    public var volume: Int
    public var phf: Float?
}

public enum Summary {
    /// Per-zone totals; zones with no events are listed with zeros when `zones` is given.
    public static func of(_ events: [CountEvent], zones: [Zone] = []) -> [ZoneSummary] {
        var order: [Int] = []
        var names: [Int: String] = [:]
        for z in zones where names[z.id] == nil {
            order.append(z.id)
            names[z.id] = z.name
        }
        for e in events where names[e.zoneId] == nil {
            order.append(e.zoneId)
            names[e.zoneId] = e.zoneName
        }
        return order.map { id in
            let ev = events.filter { $0.zoneId == id }
            let speeds = ev.compactMap { $0.speedKmh }
            var byClass: [VehicleClass: Int] = [:]
            var byDir: [String: Int] = [:]
            for e in ev {
                byClass[e.cls, default: 0] += 1
                byDir[e.direction, default: 0] += 1
            }
            return ZoneSummary(
                zoneId: id,
                zoneName: names[id] ?? "",
                total: ev.count,
                byClass: byClass,
                byDirection: byDir,
                avgSpeedKmh: speeds.isEmpty ? nil : speeds.reduce(0, +) / Float(speeds.count),
                maxSpeedKmh: speeds.max()
            )
        }
    }

    /// One event per vehicle (its first one): a vehicle crossing several boxes is counted once.
    public static func unique(_ events: [CountEvent]) -> [CountEvent] {
        var seen = Set<Int>()
        return events.sorted { $0.timeMs < $1.timeMs }.filter { seen.insert($0.trackId).inserted }
    }

    public static func byClass(_ events: [CountEvent]) -> [VehicleClass: Int] {
        var out: [VehicleClass: Int] = [:]
        for e in events { out[e.cls, default: 0] += 1 }
        return out
    }

    /// Counts per time interval. `zoneId` nil = unique vehicles over all boxes.
    /// Every interval from the start of the session to `durationMs` is listed, empty ones included.
    public static func intervals(_ events: [CountEvent], intervalMs: Int64, durationMs: Int64, zoneId: Int? = nil) -> [IntervalRow] {
        guard intervalMs > 0 else { return [] }
        let selected = zoneId.map { id in events.filter { $0.zoneId == id } } ?? unique(events)
        let last = max(durationMs, (selected.map { $0.timeMs }.max() ?? 0) + 1)
        let n = Int((last + intervalMs - 1) / intervalMs)
        var rows = (0..<max(n, 1)).map { IntervalRow(startMs: Int64($0) * intervalMs, endMs: Int64($0 + 1) * intervalMs, byClass: [:]) }
        for e in selected {
            let i = min(Int(max(e.timeMs, 0) / intervalMs), rows.count - 1)
            rows[i].byClass[e.cls, default: 0] += 1
        }
        return rows
    }

    /// Busiest 60 minutes on a 15-minute grid, with the peak hour factor PHF = V / (4 * V15max).
    /// Nil for sessions shorter than an hour.
    public static func peakHour(_ events: [CountEvent], durationMs: Int64, zoneId: Int? = nil) -> PeakHour? {
        let q: Int64 = 15 * 60 * 1000
        guard durationMs >= 4 * q else { return nil }
        let rows = intervals(events, intervalMs: q, durationMs: durationMs, zoneId: zoneId)
        guard rows.count >= 4 else { return nil }
        var best: PeakHour?
        for i in 0...(rows.count - 4) {
            let window = rows[i..<(i + 4)]
            let volume = window.reduce(0) { $0 + $1.total }
            if best == nil || volume > best!.volume {
                let maxQ = window.map { $0.total }.max() ?? 0
                best = PeakHour(startMs: rows[i].startMs, volume: volume, phf: maxQ > 0 ? Float(volume) / Float(4 * maxQ) : nil)
            }
        }
        return best
    }

    /// One human-readable line per zone, shared by the UI, the PDF export and the CI autotest.
    public static func line(_ s: ZoneSummary) -> String {
        let cls = VehicleClass.allCases.compactMap { c in s.byClass[c].map { "\(c.label) \($0)" } }.joined(separator: ", ")
        let dir = s.byDirection.keys.sorted().map { "\($0)\(s.byDirection[$0] ?? 0)" }.joined(separator: " ")
        var out = "\(s.zoneName): \(s.total)"
        if !cls.isEmpty { out += " (\(cls))" }
        if !dir.isEmpty { out += " | \(dir)" }
        if let avg = s.avgSpeedKmh {
            out += String(format: " | avg %.0f km/h, max %.0f km/h", avg, s.maxSpeedKmh ?? 0)
        }
        return out
    }
}

public enum CsvExporter {
    private static func esc(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Every counted vehicle. `video_time` (position in the video, to find it in a player) is filled for video
    /// sessions, `clock_time` when the real start time is known, `category` is the E50 form's column.
    public static func build(sessionName: String, events: [CountEvent], videoTimes: Bool = false, startEpochMs: Int64? = nil) -> String {
        var out = "session,zone,track_id,class,direction,speed_kmh,time_s,confidence,video_time,clock_time,category\n"
        for e in events {
            let speed = e.speedKmh.map { String(format: "%.1f", $0) } ?? ""
            let conf = e.score.map { String(format: "%.2f", $0) } ?? ""
            let video = videoTimes ? videoTime(e.timeMs) : ""
            let clockTime = startEpochMs.map { clock(e.timeMs, startEpochMs: $0) } ?? ""
            out += "\(esc(sessionName)),\(esc(e.zoneName)),\(e.trackId),\(e.cls.label),\(e.direction),\(speed),\(String(format: "%.2f", Double(e.timeMs) / 1000)),\(conf),"
            out += "\(video),\(clockTime),\(esc(FichaCategory(e)?.rawValue ?? ""))\n"
        }
        return out
    }

    /// Position in a video as a player shows it: "3:07" (or "1:03:07" past an hour).
    public static func videoTime(_ ms: Int64) -> String {
        let s = Int(max(ms, 0) / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "hh:mm:ss" from the start of the session, or the wall-clock time when `startEpochMs` is given.
    public static func clock(_ ms: Int64, startEpochMs: Int64? = nil) -> String {
        if let start = startEpochMs {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date(timeIntervalSince1970: Double(start + ms) / 1000))
        }
        let s = Int(ms / 1000)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// Volume table for traffic studies: one row per interval for all boxes (unique vehicles) and for each box.
    public static func intervals(sessionName: String, events: [CountEvent], zones: [Zone], intervalMs: Int64,
                                 durationMs: Int64, startEpochMs: Int64? = nil) -> String {
        let classes = VehicleClass.allCases
        var out = "session,zone,interval_start,interval_end," + classes.map { $0.rawValue }.joined(separator: ",") + ",total\n"
        var groups: [(String, Int?)] = [("All boxes (unique)", nil)]
        for s in Summary.of(events, zones: zones) { groups.append((s.zoneName, s.zoneId)) }
        for (name, id) in groups {
            for r in Summary.intervals(events, intervalMs: intervalMs, durationMs: durationMs, zoneId: id) {
                out += "\(esc(sessionName)),\(esc(name)),\(clock(r.startMs, startEpochMs: startEpochMs)),\(clock(r.endMs, startEpochMs: startEpochMs)),"
                out += classes.map { String(r.byClass[$0] ?? 0) }.joined(separator: ",") + ",\(r.total)\n"
            }
        }
        return out
    }
}
