import CoreLocation
import Foundation
import SwiftUI
import TrafficCore

enum SourceKind: String, Hashable {
    case camera, video
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
    @Published var zones: [Zone] = [Zone(id: 1, name: "Zone 1", rect: RectN(left: 0.2, top: 0.4, right: 0.8, bottom: 0.6))]
    @Published var selectedZoneId: Int? = 1
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
    @Published var modelReady = false
    @Published var snapshot: EngineSnapshot?
    @Published var elapsedMs: Int64 = 0
    @Published var sessions: [SessionRecord] = []

    let engine = AnalysisEngine()
    private let countingFlag = Flag()
    private var nextZoneId = 2
    private var source: SourceKind = .camera
    private var startedAt = Date()
    private var location: CLLocation?
    private var videoTask: Task<Void, Never>?
    private var timer: Timer?
    private let camera = CameraSource()
    private let store = SessionStore()
    private let locator = OneShotLocation()
    private var autotestStarted = false

    init() {
        sessions = store.load()
        engine.configure(zones: zones, enabled: enabledClasses)
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

    private func syncEngine() { engine.configure(zones: zones, enabled: enabledClasses) }

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

    func setRect(_ id: Int, _ rect: RectN) {
        if let i = zones.firstIndex(where: { $0.id == id }) { zones[i].rect = rect; syncEngine() }
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
        if kind == .camera { startCamera() } else { stopCamera() }
    }

    func leaveAnalysis() {
        if running { stop() }
        stopCamera()
    }

    private func startCamera() {
        let engine = engine
        let flag = countingFlag
        camera.start(
            onFrame: { [weak self] frame, t in
                let snap = engine.process(frame, tMs: t, counting: flag.value)
                Task { @MainActor in self?.snapshot = snap }
            },
            onError: { [weak self] text in Task { @MainActor in self?.message = text } }
        )
    }

    private func stopCamera() { camera.stop() }

    func loadVideo(_ url: URL) {
        videoURL = url
        message = nil
        Task {
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
        engine.reset()
        startedAt = Date()
        elapsedMs = 0
        message = nil
        running = true
        countingFlag.value = true
        fetchLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedMs = Int64(Date().timeIntervalSince(self.startedAt) * 1000)
            }
        }
        if source == .video, let url = videoURL {
            let engine = engine
            videoTask = Task.detached { [weak self] in
                do {
                    try await VideoSource.run(
                        url: url,
                        process: { frame, t in
                            let snap = engine.process(frame, tMs: t, counting: true)
                            Task { @MainActor in self?.snapshot = snap }
                        },
                        onProgress: { p in Task { @MainActor in self?.progress = p } }
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
        timer?.invalidate()
        timer = nil
        let aspect = snapshot.map { Float($0.frame.width) / Float($0.frame.height) } ?? 16.0 / 9.0
        let events = engine.finish(frameAspect: aspect)
        if let s = snapshot { snapshot = EngineSnapshot(frame: s.frame, tracks: [], events: events, fps: 0) }
        let record = SessionRecord(
            id: UUID(),
            name: "Session " + Self.nameFormatter.string(from: startedAt),
            source: source.rawValue,
            startedAt: startedAt,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            zones: zones,
            events: events
        )
        sessions.insert(record, at: 0)
        store.save(sessions)
        message = "Saved \(events.count) vehicles to History."
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.save(sessions)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func fetchLocation() {
        location = nil
        locator.onLocation = { [weak self] l in Task { @MainActor in self?.location = l } }
        locator.request()
    }

    // MARK: headless test run (CI): launch with `-autotest_video <file in Documents> -autotest_zones "l,t,r,b,len;..."`

    var autotestRequested: Bool { ProcessInfo.processInfo.arguments.contains("-autotest_video") }

    func runAutotest() {
        let args = ProcessInfo.processInfo.arguments
        guard !autotestStarted, let i = args.firstIndex(of: "-autotest_video"), i + 1 < args.count else { return }
        autotestStarted = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = docs.appendingPathComponent(args[i + 1])
        let spec = args.firstIndex(of: "-autotest_zones").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""

        let parsed: [Zone] = spec.split(separator: ";").enumerated().compactMap { n, part in
            let p = part.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count >= 4 else { return nil }
            return Zone(id: n + 1, name: "Zone \(n + 1)", rect: RectN(left: p[0], top: p[1], right: p[2], bottom: p[3]), lengthMeters: p.count > 4 ? p[4] : nil)
        }

        Task {
            guard FileManager.default.fileExists(atPath: file.path) else {
                try? "missing video".write(to: docs.appendingPathComponent("autotest_done"), atomically: true, encoding: .utf8)
                return
            }
            if !parsed.isEmpty {
                zones = parsed
                selectedZoneId = parsed.first?.id
                nextZoneId = (parsed.map { $0.id }.max() ?? 0) + 1
                syncEngine()
            }
            selectSource(.video)
            loadVideo(file)
            while !modelReady { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            start()
            while running { try? await Task.sleep(nanoseconds: 500_000_000) }

            let events = snapshot?.events ?? []
            let summary = Summary.of(events, zones: zones).map { Summary.line($0) }.joined(separator: "\n")
            try? CsvExporter.build(sessionName: "autotest", events: events)
                .write(to: docs.appendingPathComponent("autotest_result.csv"), atomically: true, encoding: .utf8)
            try? "total=\(events.count)\n\(summary)\n"
                .write(to: docs.appendingPathComponent("autotest_summary.txt"), atomically: true, encoding: .utf8)
            try? "ok".write(to: docs.appendingPathComponent("autotest_done"), atomically: true, encoding: .utf8)
        }
    }
}
