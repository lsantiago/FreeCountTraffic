import Foundation
import Security
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
    /// Header of the E50 field form, once filled in for this session.
    var ficha: FichaInfo? = nil

    var startEpochMs: Int64? { clockStart.map { Int64($0.timeIntervalSince1970 * 1000) } }

    /// Session counted from a video file: event times are positions in that video.
    var isVideo: Bool { source == SourceKind.video.rawValue }

    /// "▶ 3:07" in the video (video sessions) and "07:03:07" on the clock (when the real start time is known).
    func eventTimes(_ e: CountEvent) -> (video: String?, clock: String?) {
        (isVideo ? "▶ " + CsvExporter.videoTime(e.timeMs) : nil, startEpochMs.map { CsvExporter.clock(e.timeMs, startEpochMs: $0) })
    }

    /// ms from local midnight to the start of the session (0 when the real start time is unknown).
    var dayOffsetMs: Int64 {
        guard let start = clockStart else { return 0 }
        return Int64(start.timeIntervalSince(Calendar.current.startOfDay(for: start)) * 1000)
    }
}

/// Header fields of the E50 field form.
struct FichaInfo: Codable, Equatable {
    var title = "CAPACIDAD VIAL VÍA LOJA ZAMORA EJE VIAL E50"
    var station = ""
    var weather = ""
    var observer = ""
    var coordinator = ""
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

    /// Two files: every counted vehicle, and the 15-minute volume table; with the E50 form, a third one with the
    /// form's table (periods x movements x categories).
    static func csv(_ r: SessionRecord, ficha: Bool = false) throws -> [URL] {
        let events = tempURL(r.name + ".csv")
        try CsvExporter.build(sessionName: r.name, events: r.events, videoTimes: r.isVideo, startEpochMs: r.startEpochMs)
            .write(to: events, atomically: true, encoding: .utf8)
        let table = tempURL(r.name + "_15min.csv")
        try CsvExporter.intervals(sessionName: r.name, events: r.events, zones: r.zones, intervalMs: quarterMs,
                                  durationMs: Int64(r.durationMs), startEpochMs: r.startEpochMs)
            .write(to: table, atomically: true, encoding: .utf8)
        guard ficha else { return [events, table] }
        let form = tempURL(r.name + "_ficha.csv")
        try FichaPDF.csv(r).write(to: form, atomically: true, encoding: .utf8)
        return [events, table, form]
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

/// Small secrets (the RTSP URL carries the camera password) kept in the Keychain, on this device only.
enum Keychain {
    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.freecount.traffic", kSecAttrAccount: key]
    }

    static func string(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let attrs: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query(key).merging(attrs) { $1 } as CFDictionary, nil)
        }
    }
}
