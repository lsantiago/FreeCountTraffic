import CoreGraphics
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

/// Detector -> tracker -> zone counter pipeline shared by every frame source. Thread-safe.
final class AnalysisEngine: @unchecked Sendable {
    /// Like the reference app, only the first 500 vehicle images of a session are kept.
    static let maxThumbnails = 500

    private let lock = NSLock()
    private var detector: VehicleDetector?
    private var confidence: Float = 0.30
    private let tracker = SimpleTracker()
    private let counter = ZoneCounter()
    private var zones: [Zone] = []
    private var enabled: Set<VehicleClass> = [.car, .truck, .bus, .motorcycle]
    private var saveImages = true
    private var startMs: Int64?
    private var lastMs: Int64 = 0
    private var lastFrameTime: TimeInterval = 0
    private var fpsEma: Double = 0
    private var trailMap: [Int: [CGPoint]] = [:]
    private var thumbs: [Int: Data] = [:]
    private let maxTrailPoints = 30

    /// Loads (or swaps) the detection model.
    func loadModel(_ kind: DetectionModel) throws {
        let fresh = try VehicleDetector(kind) // heavy: build outside the lock
        lock.lock(); defer { lock.unlock() }
        fresh.confidence = confidence
        detector = fresh
    }

    func configure(zones: [Zone], enabled: Set<VehicleClass>, confidence: Float, saveImages: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.zones = zones
        self.enabled = enabled
        self.saveImages = saveImages
        if confidence != self.confidence {
            self.confidence = confidence
            detector?.confidence = confidence
        }
    }

    /// - Parameters:
    ///   - tMs: frame timestamp in ms on a monotonic clock (video position or camera presentation time).
    ///   - counting: when false the frame is only returned for display.
    func process(_ frame: CGImage, tMs rawMs: Int64, counting: Bool) -> EngineSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard counting, let detector else {
            return EngineSnapshot(frame: frame, tracks: [], events: counter.events, fps: 0)
        }
        // event times are relative to the start of the session (camera timestamps are device uptime)
        if startMs == nil { startMs = rawMs }
        let tMs = rawMs - (startMs ?? rawMs)
        lastMs = tMs

        let detections = detector.detect(frame).filter { enabled.contains($0.cls) }
        let result = tracker.update(detections, tMs: tMs)
        let aspect = Float(frame.width) / Float(frame.height)
        let produced = counter.update(zones: zones, frameAspect: aspect, active: result.active, removed: result.removed, tMs: tMs)

        if saveImages {
            for e in produced where thumbs[e.trackId] == nil && thumbs.count < Self.maxThumbnails {
                if let t = result.active.first(where: { $0.id == e.trackId }), let jpeg = Self.thumbnail(frame, t.box) {
                    thumbs[e.trackId] = jpeg
                }
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
        return EngineSnapshot(frame: frame, tracks: result.active, events: counter.events, fps: fpsEma, trails: trailMap)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker.reset()
        counter.reset()
        startMs = nil
        lastMs = 0
        lastFrameTime = 0
        fpsEma = 0
        trailMap.removeAll()
        thumbs.removeAll()
    }

    /// Adds the speed of vehicles still inside a zone and returns every event of the session, the vehicle images
    /// and the analysed span in ms.
    func finish(frameAspect: Float) -> (events: [CountEvent], thumbnails: [Int: Data], spanMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        counter.finish(zones: zones, frameAspect: frameAspect)
        return (counter.events, thumbs, lastMs)
    }

    /// Crop around the vehicle (with some margin), at most 200 px, as JPEG.
    private static func thumbnail(_ frame: CGImage, _ box: RectN) -> Data? {
        let w = CGFloat(frame.width), h = CGFloat(frame.height)
        let padX = CGFloat(box.width) * 0.15 * w, padY = CGFloat(box.height) * 0.15 * h
        let rect = CGRect(x: CGFloat(box.left) * w - padX, y: CGFloat(box.top) * h - padY,
                          width: CGFloat(box.width) * w + 2 * padX, height: CGFloat(box.height) * h + 2 * padY)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 4, rect.height >= 4, let crop = frame.cropping(to: rect) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let scale = min(1, 200 / max(rect.width, rect.height))
        var image = crop
        if scale < 1, let ctx = CGContext(data: nil, width: Int(rect.width * scale), height: Int(rect.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            image = ctx.makeImage() ?? crop
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
