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

    public static func build(sessionName: String, events: [CountEvent]) -> String {
        var out = "session,zone,track_id,class,direction,speed_kmh,time_s\n"
        for e in events {
            let speed = e.speedKmh.map { String(format: "%.1f", $0) } ?? ""
            out += "\(esc(sessionName)),\(esc(e.zoneName)),\(e.trackId),\(e.cls.label),\(e.direction),\(speed),\(String(format: "%.2f", Double(e.timeMs) / 1000))\n"
        }
        return out
    }
}
