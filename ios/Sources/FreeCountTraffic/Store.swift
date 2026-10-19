import Foundation
import TrafficCore
import UIKit

struct SessionRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var source: String
    var startedAt: Date
    /// Analysed span (video time for files, wall time for the camera).
    var durationMs: Int
    var latitude: Double?
    var longitude: Double?
    var zones: [Zone]
    var events: [CountEvent]
    /// Wall-clock time of the first analysed frame (recording date for videos), used to label intervals.
    var clockStart: Date?

    var startEpochMs: Int64? { clockStart.map { Int64($0.timeIntervalSince1970 * 1000) } }
}

/// Sessions are kept as one JSON file in the app's Documents folder (counts only, never video), plus the small
/// vehicle images used to validate detections in Documents/thumbs/<session id>/<track id>.jpg.
final class SessionStore {
    private let url: URL
    private let thumbsRoot: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("sessions.json")
        thumbsRoot = docs.appendingPathComponent("thumbs", isDirectory: true)
    }

    func load() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionRecord].self, from: data)) ?? []
    }

    func save(_ sessions: [SessionRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) { try? data.write(to: url, options: .atomic) }
    }

    func saveThumbnails(_ id: UUID, _ thumbs: [Int: Data]) {
        guard !thumbs.isEmpty else { return }
        let dir = thumbsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (track, data) in thumbs { try? data.write(to: dir.appendingPathComponent("\(track).jpg")) }
    }

    func thumbnail(_ id: UUID, track: Int) -> UIImage? {
        UIImage(contentsOfFile: thumbsRoot.appendingPathComponent(id.uuidString).appendingPathComponent("\(track).jpg").path)
    }

    func deleteThumbnails(_ id: UUID) {
        try? FileManager.default.removeItem(at: thumbsRoot.appendingPathComponent(id.uuidString))
    }
}

enum Exporter {
    static let quarterMs: Int64 = 15 * 60 * 1000

    private static func tempURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return FileManager.default.temporaryDirectory.appendingPathComponent(safe)
    }

    /// Two files: every counted vehicle, and the 15-minute volume table.
    static func csv(_ r: SessionRecord) throws -> [URL] {
        let events = tempURL(r.name + ".csv")
        try CsvExporter.build(sessionName: r.name, events: r.events).write(to: events, atomically: true, encoding: .utf8)
        let table = tempURL(r.name + "_15min.csv")
        try CsvExporter.intervals(sessionName: r.name, events: r.events, zones: r.zones, intervalMs: quarterMs,
                                  durationMs: Int64(r.durationMs), startEpochMs: r.startEpochMs)
            .write(to: table, atomically: true, encoding: .utf8)
        return [events, table]
    }

    static func pdf(_ r: SessionRecord) throws -> URL {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { ctx in
            var y: CGFloat = 40
            ctx.beginPage()
            func line(_ text: String, size: CGFloat = 11, bold: Bool = false, gap: CGFloat = 16) {
                if y > 800 { ctx.beginPage(); y = 40 }
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                (text as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [.font: font])
                y += gap
            }
            let unique = Summary.unique(r.events)
            line("Traffic count - \(r.name)", size: 18, bold: true, gap: 26)
            line("Started: \(DateFormatter.localizedString(from: r.startedAt, dateStyle: .medium, timeStyle: .short))   Source: \(r.source)")
            line("Duration: \(CsvExporter.clock(Int64(r.durationMs)))")
            if let lat = r.latitude, let lon = r.longitude { line(String(format: "Location: %.5f, %.5f", lat, lon)) }
            y += 8
            line("Summary", size: 15, bold: true, gap: 24)
            let cls = VehicleClass.allCases.compactMap { c in Summary.byClass(unique)[c].map { "\(c.label) \($0)" } }.joined(separator: ", ")
            line("Unique vehicles: \(unique.count)" + (cls.isEmpty ? "" : " (\(cls))"))
            for s in Summary.of(r.events, zones: r.zones) { line(Summary.line(s)) }
            if let p = Summary.peakHour(r.events, durationMs: Int64(r.durationMs)) {
                let phf = p.phf.map { String(format: ", PHF %.2f", $0) } ?? ""
                line("Peak hour: \(CsvExporter.clock(p.startMs, startEpochMs: r.startEpochMs))-\(CsvExporter.clock(p.startMs + 4 * quarterMs, startEpochMs: r.startEpochMs)), \(p.volume) vehicles\(phf)")
            }
            y += 8
            line("15-minute volumes (unique vehicles)", size: 15, bold: true, gap: 24)
            line("interval  " + VehicleClass.allCases.map { $0.label }.joined(separator: "  ") + "  total")
            for row in Summary.intervals(r.events, intervalMs: quarterMs, durationMs: Int64(r.durationMs)) {
                let counts = VehicleClass.allCases.map { String(row.byClass[$0] ?? 0) }.joined(separator: "  ")
                line("\(CsvExporter.clock(row.startMs, startEpochMs: r.startEpochMs))  \(counts)  \(row.total)")
            }
            y += 8
            line("Vehicles", size: 15, bold: true, gap: 24)
            line("time  zone  class  direction  speed(km/h)  confidence")
            for e in r.events {
                let speed = e.speedKmh.map { String(format: "%.0f", $0) } ?? "-"
                let conf = e.score.map { String(format: "%.0f%%", $0 * 100) } ?? "-"
                line("\(CsvExporter.clock(e.timeMs, startEpochMs: r.startEpochMs))  \(e.zoneName)  \(e.cls.label)  \(e.direction)  \(speed)  \(conf)")
            }
        }
        let url = tempURL(r.name + ".pdf")
        try data.write(to: url)
        return url
    }
}
