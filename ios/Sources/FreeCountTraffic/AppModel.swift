import AVFoundation
import CoreLocation
import Foundation
import SwiftUI
import TrafficCore
#if canImport(UIKit)
import UIKit
#endif

enum SourceKind: String, Hashable {
    case camera, video, rtsp
}

/// Small lock-protected flag read from camera/video threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Lets through at most one UI update every `minGap` seconds and none while the previous one is still waiting for
/// the main thread, so fast detection never floods the UI (which made button taps get lost).
final class UiGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minGap: TimeInterval
    private var busy = false
    private var last = Date.distantPast

    init(minGap: TimeInterval) { self.minGap = minGap }

    func tryEnter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if busy || now.timeIntervalSince(last) < minGap { return false }
        busy = true
        last = now
        return true
    }

    func leave() { lock.lock(); busy = false; lock.unlock() }
}

final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?

    func request() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { onLocation?(l) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: break
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// The last-used boxes are kept between launches, like the reference app.
    @Published var zones: [Zone] = {
        if let data = UserDefaults.standard.data(forKey: "zones"),
           let saved = try? JSONDecoder().decode([Zone].self, from: data), !saved.isEmpty { return saved }
        return [Zone(id: 1, name: "Zone 1", rect: RectN(left: 0.2, top: 0.4, right: 0.8, bottom: 0.6))]
    }()
    @Published var selectedZoneId: Int?
    /// Part of the frame analysed (nil = whole frame).
    @Published var studyArea: RectN? = {
        guard let data = UserDefaults.standard.data(forKey: "studyArea") else { return nil }
        return try? JSONDecoder().decode(RectN.self, from: data)
    }()
    /// Name of the next session: video file name, or the address from GPS for the camera; editable.
    @Published var sessionName = ""
    @Published var confidence: Float = UserDefaults.standard.object(forKey: "confidence") as? Float ?? 0.30 {
        didSet { UserDefaults.standard.set(confidence, forKey: "confidence"); syncEngine() }
    }
    @Published var saveImages: Bool = UserDefaults.standard.object(forKey: "saveImages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveImages, forKey: "saveImages"); syncEngine() }
    }
    @Published var running = false
    @Published var soundOn: Bool = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "soundOn") }
    }
    @Published var showFps: Bool = UserDefaults.standard.object(forKey: "showFps") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFps, forKey: "showFps") }
    }
    @Published var detectionModel: DetectionModel = DetectionModel(rawValue: UserDefaults.standard.string(forKey: "detectionModel") ?? "") ?? .balanced
    @Published var enabledClasses: Set<VehicleClass> = {
        let saved = (UserDefaults.standard.stringArray(forKey: "enabledClasses") ?? []).compactMap { VehicleClass(rawValue: $0) }
        return saved.isEmpty ? [.car, .truck, .bus, .motorcycle] : Set(saved)
    }()
    @Published var message: String?
    @Published var progress: Double?
    @Published var videoURL: URL?
    /// Last stream connected to (kept in the Keychain: it usually carries the camera password).
    @Published var rtspUrl = Keychain.string("rtspUrl") ?? ""
    /// Stream being played (nil = not connected).
    @Published var rtspActive: String?
    @Published var modelReady = false
    @Published var snapshot: EngineSnapshot?
    @Published var elapsedMs: Int64 = 0
    @Published var sessions: [SessionRecord] = []

    let engine = AnalysisEngine()
    private let countingFlag = Flag()
    private let frameGate = UiGate(minGap: 1.0 / 30)
    private let progressGate = UiGate(minGap: 0.25)
    private var nextZoneId = 2
    private var source: SourceKind = .camera
    private var startedAt = Date()
    private var location: CLLocation?
    private var videoTask: Task<Void, Never>?
    private var timer: Timer?
    private let camera = CameraSource()
    private let rtsp = RtspSource()
    private let store = SessionStore()
    private let locator = OneShotLocation()
    private var autotestStarted = false
    private var nameEdited = false
    private var clockStart: Date?
    private let geocoder = CLGeocoder()

    init() {
        sessions = store.load()
        selectedZoneId = zones.first?.id
        nextZoneId = (zones.map { $0.id }.max() ?? 0) + 1
        syncEngine()
        loadDetector(detectionModel)
    }

    private func loadDetector(_ kind: DetectionModel) {
        modelReady = false
        let engine = engine
        Task.detached { [weak self] in
            do {
                try engine.loadModel(kind)
                await MainActor.run { self?.modelReady = true }
            } catch {
                let text = error.localizedDescription
                await MainActor.run { self?.message = "Could not load the detection model: \(text)" }
            }
        }
    }

    /// Settings: switch between High Accuracy / Balanced / Fastest (not while counting).
    func setDetectionModel(_ kind: DetectionModel) {
        guard !running, kind != detectionModel else { return }
        detectionModel = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "detectionModel")
        loadDetector(kind)
    }

    // MARK: boxes

    private func syncEngine() {
        engine.configure(zones: zones, enabled: enabledClasses, confidence: confidence, saveImages: saveImages, studyArea: studyArea)
        if let data = try? JSONEncoder().encode(zones) { UserDefaults.standard.set(data, forKey: "zones") }
    }

    func setDirection(_ id: Int, _ heading: Heading?) {
        if let i = zones.firstIndex(where: { $0.id == id }) { zones[i].direction = heading; syncEngine() }
    }

    func setSessionName(_ name: String) {
        sessionName = name
        nameEdited = true
    }

    func addZone() {
        let id = nextZoneId
        nextZoneId += 1
        let off = Float((id - 1) % 4) * 0.05
        zones.append(Zone(id: id, name: "Zone \(id)", rect: RectN(left: 0.15 + off, top: 0.3 + off, right: 0.55 + off, bottom: 0.5 + off)))
        selectedZoneId = id
        syncEngine()
    }

    func deleteZone(_ id: Int) {
        zones.removeAll { $0.id == id }
        selectedZoneId = zones.first?.id
        syncEngine()
    }

    func setRect(_ id: Int, _ rect: RectN, angle: Float? = nil) {
        if let i = zones.firstIndex(where: { $0.id == id }) {
            zones[i].rect = rect
            zones[i].angle = angle.flatMap { $0 == 0 ? nil : $0 }
            syncEngine()
        }
    }

    /// Box settings: exact rotation (clockwise radians, 0 = straight).
    func setAngle(_ id: Int, _ angle: Float) {
        if let i = zones.firstIndex(where: { $0.id == id }) {
            zones[i].angle = abs(angle) < 0.0001 ? nil : angle
            syncEngine()
        }
    }

    func setStudyArea(_ area: RectN?) {
        studyArea = area
        if let area, let data = try? JSONEncoder().encode(area) {
            UserDefaults.standard.set(data, forKey: "studyArea")
        } else {
            UserDefaults.standard.removeObject(forKey: "studyArea")
        }
        syncEngine()
    }

    func rename(_ id: Int, _ name: String) {
        if let i = zones.firstIndex(where: { $0.id == id }) { zones[i].name = name; syncEngine() }
    }

    func setLength(_ id: Int, _ meters: Float?) {
        if let i = zones.firstIndex(where: { $0.id == id }) { zones[i].lengthMeters = meters; syncEngine() }
    }

    func toggleClass(_ c: VehicleClass) {
        if enabledClasses.contains(c) { enabledClasses.remove(c) } else { enabledClasses.insert(c) }
        UserDefaults.standard.set(enabledClasses.map { $0.rawValue }, forKey: "enabledClasses")
        syncEngine()
    }

    // MARK: sources

    func selectSource(_ kind: SourceKind) {
        if running { return }
        source = kind
        engine.reset()
        progress = nil
        message = nil
        snapshot = nil
        sessionName = ""
        nameEdited = false
        lastSessionId = nil
        if kind == .camera { startCamera() } else { stopCamera() }
        stopRtsp()
    }

    func leaveAnalysis() {
        if running { stop() }
        stopCamera()
        stopRtsp()
        lastSessionId = nil
        keepFinishedSession = false
    }

    /// Set when the results of the session just finished are opened from the analysis screen, so coming back keeps
    /// its counts and the Show results / Reset buttons instead of starting over.
    private var keepFinishedSession = false

    /// Opening the analysis screen: a fresh start, unless coming back from the results of the session just finished.
    func enterAnalysis(_ kind: SourceKind) {
        if keepFinishedSession && kind == source && lastSessionId != nil {
            keepFinishedSession = false
            if kind == .camera { startCamera() }
            return
        }
        keepFinishedSession = false
        selectSource(kind)
    }

    /// "Show results" after a session: the analysis screen keeps its state for when the user comes back.
    func openFinishedResults() { keepFinishedSession = true }

    /// "Reset" after a session (like the reference app): clears the counts and goes back to "Start counting",
    /// keeping the boxes, the source and the chosen video.
    func resetSession() {
        guard !running else { return }
        engine.reset()
        lastSessionId = nil
        keepFinishedSession = false
        progress = nil
        message = nil
        if source != .video && !nameEdited { sessionName = "" }
        if let s = snapshot { snapshot = EngineSnapshot(frame: s.frame, tracks: [], events: [], fps: 0) }
        if source == .video, let url = videoURL {
            Task {
                if let frame = await VideoSource.firstFrame(url) { snapshot = EngineSnapshot(frame: frame, tracks: [], events: [], fps: 0) }
            }
        }
    }

    /// Live frames (camera, RTSP): shown at once and analysed while counting.
    private func liveFrameHandler() -> @Sendable (CGImage, Int64) -> Void {
        let engine = engine
        let flag = countingFlag
        let gate = frameGate
        return { [weak self] frame, t in
            let snap = engine.process(frame, tMs: t, counting: flag.value)
            guard gate.tryEnter() else { return }
            Task { @MainActor in self?.snapshot = snap; gate.leave() }
        }
    }

    private func startCamera() {
        camera.start(
            onFrame: liveFrameHandler(),
            onError: { [weak self] text in Task { @MainActor in self?.message = text } }
        )
    }

    /// Connects (or reconnects) to `rtspUrl`; frames arrive like the camera's.
    func connectRtsp() {
        let url = rtspUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.lowercased().hasPrefix("rtsp://") else { message = "URL must start with rtsp://"; return }
        rtspActive = url
        Keychain.set("rtspUrl", url)
        if !running { snapshot = nil }
        message = "Connecting…"
        rtsp.start(
            url: url,
            onFrame: liveFrameHandler(),
            onStatus: { [weak self] text in Task { @MainActor in self?.message = text } }
        )
    }

    private func stopRtsp() {
        rtsp.stop()
        rtspActive = nil
    }

    private func stopCamera() { camera.stop() }

    func loadVideo(_ url: URL, displayName: String? = nil) {
        videoURL = url
        message = nil
        if !nameEdited { sessionName = displayName ?? url.deletingPathExtension().lastPathComponent }
        clockStart = nil
        Task {
            // recording date of the video labels the intervals with real clock times
            if let date = try? await AVURLAsset(url: url).load(.creationDate)?.load(.dateValue) {
                clockStart = date
                if !nameEdited && sessionName == "Video" { sessionName = "Video " + Self.nameFormatter.string(from: date) }
            }
            if let frame = await VideoSource.firstFrame(url) {
                snapshot = EngineSnapshot(frame: frame, tracks: [], events: [], fps: 0)
            } else {
                message = "Could not read that video."
            }
        }
    }

    // MARK: sessions

    func start() {
        guard !running, modelReady else { return }
        if source == .video && videoURL == nil { message = "Choose a video first."; return }
        if source == .rtsp && snapshot == nil { message = "Connect to a stream first."; return }
        engine.reset()
        startedAt = Date()
        if source != .video {
            clockStart = startedAt
            if !nameEdited { sessionName = "Session " + Self.nameFormatter.string(from: startedAt) }
        }
        elapsedMs = 0
        message = nil
        running = true
        countingFlag.value = true
        setScreenAlwaysOn(true)
        fetchLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedMs = Int64(Date().timeIntervalSince(self.startedAt) * 1000)
            }
        }
        if source == .video, let url = videoURL {
            let engine = engine
            let gate = frameGate
            let pGate = progressGate
            videoTask = Task.detached { [weak self] in
                do {
                    try await VideoSource.run(
                        url: url,
                        process: { frame, t in
                            let snap = engine.process(frame, tMs: t, counting: true)
                            guard gate.tryEnter() else { return }
                            Task { @MainActor in self?.snapshot = snap; gate.leave() }
                        },
                        onProgress: { p in
                            guard p >= 1 || pGate.tryEnter() else { return }
                            Task { @MainActor in self?.progress = p; pGate.leave() }
                        }
                    )
                } catch is CancellationError {
                } catch {
                    let text = error.localizedDescription
                    await MainActor.run { self?.message = "Video error: \(text)" }
                }
                await MainActor.run { self?.finishSession() }
            }
        }
    }

    func stop() {
        videoTask?.cancel()
        if source != .video { finishSession() }
    }

    private func finishSession() {
        guard running else { return }
        running = false
        countingFlag.value = false
        setScreenAlwaysOn(false)
        timer?.invalidate()
        timer = nil
        let aspect = snapshot.map { Float($0.frame.width) / Float($0.frame.height) } ?? 16.0 / 9.0
        let result = engine.finish(frameAspect: aspect)
        let events = result.events
        if let s = snapshot { snapshot = EngineSnapshot(frame: s.frame, tracks: [], events: events, fps: 0) }
        let name = sessionName.trimmingCharacters(in: .whitespaces)
        let record = SessionRecord(
            id: UUID(),
            name: name.isEmpty ? "Session " + Self.nameFormatter.string(from: startedAt) : name,
            source: source.rawValue,
            startedAt: startedAt,
            durationMs: source == .video ? Int(result.spanMs) : Int(Date().timeIntervalSince(startedAt) * 1000),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            zones: zones,
            events: events,
            clockStart: clockStart
        )
        store.saveThumbnails(record.id, result.thumbnails)
        sessions.insert(record, at: 0)
        store.save(sessions)
        lastSessionId = record.id
        message = "Saved \(Summary.unique(events).count) vehicles to History."
    }

    /// Most recent session saved from the analysis screen (its results can be opened from there).
    @Published var lastSessionId: UUID?

    /// Keeps the screen from auto-locking while counting: a locked screen suspends the app and cuts the analysis short.
    private func setScreenAlwaysOn(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.save(sessions)
        store.deleteThumbnails(id)
    }

    func renameSession(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].name = clean
        store.save(sessions)
    }

    /// Validation: remove a wrong detection from one box.
    func deleteEvent(_ id: UUID, zoneId: Int, trackId: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].events.removeAll { $0.zoneId == zoneId && $0.trackId == trackId }
        store.save(sessions)
    }

    /// Validation: fix the class of a vehicle (in every box it crossed).
    func reclassify(_ id: UUID, trackId: Int, to cls: VehicleClass) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        for j in sessions[i].events.indices where sessions[i].events[j].trackId == trackId { sessions[i].events[j].cls = cls }
        store.save(sessions)
    }

    func thumbnail(_ id: UUID, trackId: Int) -> UIImage? { store.thumbnail(id, track: trackId) }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// For the camera, the session is named after the street address (when the user did not type a name).
    private func fetchLocation() {
        location = nil
        locator.onLocation = { [weak self] l in
            Task { @MainActor in
                guard let self else { return }
                self.location = l
                guard self.source == .camera, !self.nameEdited else { return }
                if let p = try? await self.geocoder.reverseGeocodeLocation(l).first {
                    let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
                    let address = [street.isEmpty ? nil : street, p.locality].compactMap { $0 }.joined(separator: ", ")
                    if !address.isEmpty && !self.nameEdited { self.sessionName = address }
                }
            }
        }
        locator.request()
    }

    // MARK: headless test run (CI): launch with `-autotest_video <file in Documents> -autotest_zones "l,t,r,b,len;..."`,
    // or `-autotest_rtsp <url> [-autotest_seconds N]` to count a stream for N seconds (default 30)

    /// 1 = open results, 2 = show graph, 3 = close graph, 4 = validate the first box.
    @Published var autotestStage = 0

    var autotestRequested: Bool { Self.arg("-autotest_video") != nil || Self.arg("-autotest_rtsp") != nil }
    var autotestSource: SourceKind { Self.arg("-autotest_rtsp") != nil ? .rtsp : .video }

    private static func arg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func runAutotest() {
        guard !autotestStarted, autotestRequested else { return }
        autotestStarted = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let streamUrl = Self.arg("-autotest_rtsp")
        let file = docs.appendingPathComponent(Self.arg("-autotest_video") ?? "")
        let seconds = UInt64(Self.arg("-autotest_seconds") ?? "") ?? 30
        let spec = Self.arg("-autotest_zones") ?? ""

        let parsed: [Zone] = spec.split(separator: ";").enumerated().compactMap { n, part in
            let p = part.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count >= 4 else { return nil }
            return Zone(id: n + 1, name: "Zone \(n + 1)", rect: RectN(left: p[0], top: p[1], right: p[2], bottom: p[3]), lengthMeters: p.count > 4 ? p[4] : nil)
        }

        Task {
            guard streamUrl != nil || FileManager.default.fileExists(atPath: file.path) else {
                try? "missing video".write(to: docs.appendingPathComponent("autotest_done"), atomically: true, encoding: .utf8)
                return
            }
            if !parsed.isEmpty {
                zones = parsed
                selectedZoneId = parsed.first?.id
                nextZoneId = (parsed.map { $0.id }.max() ?? 0) + 1
                syncEngine()
            }
            if let streamUrl {
                selectSource(.rtsp)
                rtspUrl = streamUrl
                connectRtsp()
                for _ in 0..<300 where snapshot == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard snapshot != nil else {
                    try? "no rtsp frames: \(message ?? "")".write(to: docs.appendingPathComponent("autotest_done"), atomically: true, encoding: .utf8)
                    return
                }
            } else {
                selectSource(.video)
                loadVideo(file)
            }
            while !modelReady { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            start()
            if streamUrl != nil {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                stop()
            }
            while running { try? await Task.sleep(nanoseconds: 500_000_000) }

            let events = snapshot?.events ?? []
            let summary = Summary.of(events, zones: zones).map { Summary.line($0) }.joined(separator: "\n")
            try? CsvExporter.build(sessionName: "autotest", events: events)
                .write(to: docs.appendingPathComponent("autotest_result.csv"), atomically: true, encoding: .utf8)
            let thumbs = sessions.first.map { s in events.filter { store.thumbnail(s.id, track: $0.trackId) != nil }.count } ?? 0
            try? "total=\(events.count)\nunique=\(Summary.unique(events).count)\nimages=\(thumbs)\n\(summary)\n"
                .write(to: docs.appendingPathComponent("autotest_summary.txt"), atomically: true, encoding: .utf8)
            try? "ok".write(to: docs.appendingPathComponent("autotest_done"), atomically: true, encoding: .utf8)

            // UI tour for the CI screenshots: results (+1 s), graph (+6 s), validation (+13 s)
            for (delay, stage) in [(1, 1), (5, 2), (6, 3), (1, 4)] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                autotestStage = stage
            }
        }
    }
}
