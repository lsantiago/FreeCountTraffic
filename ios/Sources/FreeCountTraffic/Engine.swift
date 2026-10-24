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
    /// E50 form: every truck keeps its image (beyond the 500 limit and with images off), since a person classifies
    /// trucks by axles from it.
    private var keepTruckImages = false
    /// Area of study: when set, only this part of the frame is analysed (at full detector resolution, so distant
    /// vehicles are found more easily).
    private var studyArea: RectN?
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

    func configure(zones: [Zone], enabled: Set<VehicleClass>, confidence: Float, saveImages: Bool, keepTruckImages: Bool,
                   studyArea: RectN?) {
        lock.lock(); defer { lock.unlock() }
        self.zones = zones
        self.studyArea = studyArea
        self.enabled = enabled
        self.saveImages = saveImages
        self.keepTruckImages = keepTruckImages
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

        let detections = Self.detect(detector, frame, in: studyArea).filter { enabled.contains($0.cls) }
        let result = tracker.update(detections, tMs: tMs)
        let aspect = Float(frame.width) / Float(frame.height)
        let produced = counter.update(zones: zones, frameAspect: aspect, active: result.active, removed: result.removed, tMs: tMs)

        for e in produced where thumbs[e.trackId] == nil {
            guard (saveImages && thumbs.count < Self.maxThumbnails) || (keepTruckImages && e.cls == .truck) else { continue }
            if let t = result.active.first(where: { $0.id == e.trackId }), let jpeg = Self.thumbnail(frame, t.box) {
                thumbs[e.trackId] = jpeg
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
        return EngineSnapshot(frame: frame, tracks: visible, events: counter.events, fps: fpsEma, trails: trailMap)
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

    /// Runs the detector on the study area only and maps the boxes back to the whole frame.
    private static func detect(_ detector: VehicleDetector, _ frame: CGImage, in area: RectN?) -> [Detection] {
        let w = CGFloat(frame.width), h = CGFloat(frame.height)
        guard let area, area.width < 0.98 || area.height < 0.98 else { return detector.detect(frame) }
        let rect = CGRect(x: CGFloat(area.left) * w, y: CGFloat(area.top) * h,
                          width: CGFloat(area.width) * w, height: CGFloat(area.height) * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 32, rect.height >= 32, let crop = frame.cropping(to: rect) else { return detector.detect(frame) }
        let l = Float(rect.minX / w), t = Float(rect.minY / h), sw = Float(rect.width / w), sh = Float(rect.height / h)
        return detector.detect(crop).map { d in
            var d = d
            d.box = RectN(left: l + d.box.left * sw, top: t + d.box.top * sh, right: l + d.box.right * sw, bottom: t + d.box.bottom * sh)
            return d
        }
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
