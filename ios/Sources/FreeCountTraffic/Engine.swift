import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import TrafficCore
import UniformTypeIdentifiers

struct EngineSnapshot {
    var frame: CGImage
    var tracks: [Track]
    var events: [CountEvent]
    var fps: Double
    /// Recent centre points (normalized) per track id, drawn as the trailing line.
    var trails: [Int: [CGPoint]] = [:]
}

/// What the engine found in one frame; the caller adds the picture only when the frame is shown.
struct EngineResult {
    var tracks: [Track]
    var events: [CountEvent]
    var fps: Double
    var trails: [Int: [CGPoint]]

    func snapshot(_ frame: CGImage) -> EngineSnapshot {
        EngineSnapshot(frame: frame, tracks: tracks, events: events, fps: fps, trails: trails)
    }
}

/// Which vehicle photos to keep (Settings > Save Object Images).
struct ImageSettings {
    var on = true
    var policy: [VehicleClass: ImagePolicy] = [:]
    /// Photos per class and session; 0 = no limit.
    var limit = 500
    /// E50 form: trucks and buses always keep their photo (they are classified from it), with no limit.
    var ficha = false

    private func forced(_ c: VehicleClass) -> Bool { ficha && (c == .truck || c == .bus) }
    func policy(for c: VehicleClass) -> ImagePolicy { forced(c) ? .all : (on ? policy[c] ?? .all : .none) }
    func limited(_ c: VehicleClass) -> Bool { !forced(c) && limit > 0 }
}

/// Detector -> tracker -> zone counter pipeline shared by every frame source. Thread-safe.
final class AnalysisEngine: @unchecked Sendable {
    /// Longest side of a vehicle image: large enough to see the axles of a truck.
    private static let thumbnailSide: CGFloat = 320

    private let lock = NSLock()
    private var detector: VehicleDetector?
    private var confidence: Float = 0.30
    private let tracker = SimpleTracker()
    private let counter = ZoneCounter()
    private var zones: [Zone] = []
    private var enabled: Set<VehicleClass> = [.car, .truck, .bus, .motorcycle]
    private var images = ImageSettings()
    private let writer = ThumbnailWriter()
    /// Vehicles already counted once (their photo decision is taken on their first count).
    private var seenTracks = Set<Int>()
    private var vehiclesByClass: [VehicleClass: Int] = [:]
    private var photosByClass: [VehicleClass: Int] = [:]
    private var limitReached = Set<VehicleClass>()
    /// Area of study: when set, only this part of the frame is analysed (cut from the full-resolution frame, so
    /// distant vehicles are found more easily).
    private var studyArea: RectN?
    private var startMs: Int64?
    private var lastMs: Int64 = 0
    private var lastFrameTime: TimeInterval = 0
    private var fpsEma: Double = 0
    /// Time the detector takes per frame (ms, smoothed), for the session's device log.
    private var detectMsEma: Double = 0
    private var trailMap: [Int: [CGPoint]] = [:]
    private let maxTrailPoints = 30

    /// Loads (or swaps) the detection model.
    func loadModel(_ kind: DetectionModel) throws {
        let fresh = try VehicleDetector(kind) // heavy: build outside the lock
        lock.lock(); defer { lock.unlock() }
        fresh.confidence = confidence
        detector = fresh
    }

    func configure(zones: [Zone], enabled: Set<VehicleClass>, confidence: Float, images: ImageSettings, studyArea: RectN?) {
        lock.lock(); defer { lock.unlock() }
        self.zones = zones
        self.studyArea = studyArea
        self.enabled = enabled
        self.images = images
        if confidence != self.confidence {
            self.confidence = confidence
            detector?.confidence = confidence
        }
    }

    /// Frames analysed per second and detector time per frame (ms), both smoothed.
    var stats: (fps: Double, detectMs: Double) {
        lock.lock(); defer { lock.unlock() }
        return (fpsEma, detectMsEma)
    }

    /// - Parameters:
    ///   - frame: the source's pixel buffer with its timestamp in ms on a monotonic clock (video position or camera
    ///     presentation time). The detector reads it directly, with no conversion.
    ///   - counting: when false nothing is analysed (the frame is only shown).
    func process(_ frame: FrameInput, counting: Bool) -> EngineResult {
        lock.lock(); defer { lock.unlock() }
        guard counting, let detector else {
            return EngineResult(tracks: [], events: counter.events, fps: 0, trails: [:])
        }
        // event times are relative to the start of the session (camera timestamps are device uptime)
        if startMs == nil { startMs = frame.tMs }
        let tMs = frame.tMs - (startMs ?? frame.tMs)
        lastMs = tMs

        let t0 = DispatchTime.now().uptimeNanoseconds
        let detections = detector.detect(frame, area: studyArea).filter { enabled.contains($0.cls) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        detectMsEma = detectMsEma == 0 ? ms : 0.9 * detectMsEma + 0.1 * ms

        let result = tracker.update(detections, tMs: tMs)
        let produced = counter.update(zones: zones, frameAspect: frame.aspect, active: result.active, removed: result.removed, tMs: tMs)

        for e in produced where seenTracks.insert(e.trackId).inserted {
            let c = e.cls
            vehiclesByClass[c, default: 0] += 1
            switch images.policy(for: c) {
            case .none: continue
            case .sample: if (vehiclesByClass[c, default: 1] - 1) % ImagePolicy.sampleEvery != 0 { continue }
            case .all: break
            }
            if images.limited(c) && photosByClass[c, default: 0] >= images.limit {
                limitReached.insert(c)
                continue
            }
            if let t = result.active.first(where: { $0.id == e.trackId }), let jpeg = Self.thumbnail(frame, t.box) {
                photosByClass[c, default: 0] += 1
                writer.write(jpeg, track: e.trackId)   // written right away, on the writer's own queue
            }
        }

        let alive = Set(result.active.map { $0.id })
        for id in trailMap.keys where !alive.contains(id) { trailMap.removeValue(forKey: id) }
        for t in result.active where t.lastSeenMs == tMs {
            var pts = trailMap[t.id] ?? []
            pts.append(CGPoint(x: CGFloat(t.box.cx), y: CGFloat(t.box.cy)))
            if pts.count > maxTrailPoints { pts.removeFirst(pts.count - maxTrailPoints) }
            trailMap[t.id] = pts
        }

        let now = Date().timeIntervalSinceReferenceDate
        if lastFrameTime != 0 {
            let inst = 1.0 / max(now - lastFrameTime, 0.001)
            fpsEma = fpsEma == 0 ? inst : 0.8 * fpsEma + 0.2 * inst
        }
        lastFrameTime = now
        // only vehicles detected in this frame are drawn: a track the tracker keeps alive for a moment after the
        // vehicle is gone (to bridge missed detections) must not leave its box behind on screen
        let visible = result.active.filter { $0.lastSeenMs == tMs }
        return EngineResult(tracks: visible, events: counter.events, fps: fpsEma, trails: trailMap)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker.reset()
        counter.reset()
        startMs = nil
        lastMs = 0
        lastFrameTime = 0
        fpsEma = 0
        detectMsEma = 0
        trailMap.removeAll()
        seenTracks.removeAll()
        vehiclesByClass.removeAll()
        photosByClass.removeAll()
        limitReached.removeAll()
    }

    /// Where the photos of the session about to start are written.
    func beginImages(_ dir: URL) { writer.begin(dir) }

    /// Adds the speed of vehicles still inside a zone and returns every event of the session, its photo counts per
    /// class, the analysed span in ms and whether photos stopped because the phone ran out of space.
    func finish(frameAspect: Float) -> (events: [CountEvent], images: [String: ImageStat], spanMs: Int64, lowSpace: Bool) {
        lock.lock(); defer { lock.unlock() }
        counter.finish(zones: zones, frameAspect: frameAspect)
        var stats: [String: ImageStat] = [:]
        for (c, n) in vehiclesByClass {
            stats[c.rawValue] = ImageStat(photos: photosByClass[c] ?? 0, vehicles: n, policy: images.policy(for: c),
                                          limitReached: limitReached.contains(c))
        }
        let lowSpace = writer.finish()   // waits for the last photos
        return (counter.events, stats, lastMs, lowSpace)
    }

    /// Crop around the vehicle (with some margin) from the full-resolution frame, at most `thumbnailSide` px, as JPEG.
    private static func thumbnail(_ frame: FrameInput, _ box: RectN) -> Data? {
        let image = frame.image
        let e = image.extent
        let w = e.width, h = e.height
        let padX = CGFloat(box.width) * 0.15 * w, padY = CGFloat(box.height) * 0.15 * h
        // Core Image's origin is at the bottom left
        let rect = CGRect(x: e.minX + CGFloat(box.left) * w - padX, y: e.minY + (1 - CGFloat(box.bottom)) * h - padY,
                          width: CGFloat(box.width) * w + 2 * padX, height: CGFloat(box.height) * h + 2 * padY)
            .intersection(e).integral
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        let scale = min(1, thumbnailSide / max(rect.width, rect.height))
        let crop = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = sharedCIContext.createCGImage(crop, from: crop.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
