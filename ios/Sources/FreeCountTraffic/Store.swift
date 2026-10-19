import Foundation
import TrafficCore
import UIKit

struct SessionRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var source: String
    var startedAt: Date
    var durationMs: Int
    var latitude: Double?
    var longitude: Double?
    var zones: [Zone]
    var events: [CountEvent]
}

/// Sessions are kept as one JSON file in the app's Documents folder (counts only, never video).
final class SessionStore {
    private let url: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("sessions.json")
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
}

enum Exporter {
    private static func tempURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return FileManager.default.temporaryDirectory.appendingPathComponent(safe)
    }

    static func csv(_ r: SessionRecord) throws -> URL {
        let url = tempURL(r.name + ".csv")
        try CsvExporter.build(sessionName: r.name, events: r.events).write(to: url, atomically: true, encoding: .utf8)
        return url
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
            line("Traffic count - \(r.name)", size: 18, bold: true, gap: 26)
            line("Started: \(DateFormatter.localizedString(from: r.startedAt, dateStyle: .medium, timeStyle: .short))   Source: \(r.source)")
            line("Duration: \(r.durationMs / 1000) s")
            if let lat = r.latitude, let lon = r.longitude { line(String(format: "Location: %.5f, %.5f", lat, lon)) }
            y += 8
            line("Summary", size: 15, bold: true, gap: 24)
            for s in Summary.of(r.events, zones: r.zones) { line(Summary.line(s)) }
            y += 8
            line("Vehicles", size: 15, bold: true, gap: 24)
            line("time(s)  zone  class  direction  speed(km/h)")
            for e in r.events {
                let speed = e.speedKmh.map { String(format: "%.0f", $0) } ?? "-"
                line(String(format: "%.1f  %@  %@  %@  %@", Double(e.timeMs) / 1000, e.zoneName, e.cls.label, e.direction, speed))
            }
        }
        let url = tempURL(r.name + ".pdf")
        try data.write(to: url)
        return url
    }
}
