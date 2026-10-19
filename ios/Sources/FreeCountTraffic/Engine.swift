import CoreGraphics
import Foundation
import TrafficCore

struct EngineSnapshot {
    var frame: CGImage
    var tracks: [Track]
    var events: [CountEvent]
    var fps: Double
}

/// Detector -> tracker -> zone counter pipeline shared by every frame source. Thread-safe.
final class AnalysisEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: VehicleDetector?
    private let tracker = SimpleTracker()
    private let counter = ZoneCounter()
    private var zones: [Zone] = []
    private var enabled: Set<VehicleClass> = [.car, .truck, .bus, .motorcycle]
    private var lastFrameTime: TimeInterval = 0
    private var fpsEma: Double = 0

    func loadModel() throws {
        lock.lock(); defer { lock.unlock() }
        if detector == nil { detector = try VehicleDetector() }
    }

    func configure(zones: [Zone], enabled: Set<VehicleClass>) {
        lock.lock(); defer { lock.unlock() }
        self.zones = zones
        self.enabled = enabled
    }

    /// - Parameters:
    ///   - tMs: frame timestamp in ms on a monotonic clock (video position or camera presentation time).
    ///   - counting: when false the frame is only returned for display.
    func process(_ frame: CGImage, tMs: Int64, counting: Bool) -> EngineSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard counting, let detector else {
            return EngineSnapshot(frame: frame, tracks: [], events: counter.events, fps: 0)
        }
        let detections = detector.detect(frame).filter { enabled.contains($0.cls) }
        let result = tracker.update(detections, tMs: tMs)
        let aspect = Float(frame.width) / Float(frame.height)
        counter.update(zones: zones, frameAspect: aspect, active: result.active, removed: result.removed, tMs: tMs)

        let now = Date().timeIntervalSinceReferenceDate
        if lastFrameTime != 0 {
            let inst = 1.0 / max(now - lastFrameTime, 0.001)
            fpsEma = fpsEma == 0 ? inst : 0.8 * fpsEma + 0.2 * inst
        }
        lastFrameTime = now
        return EngineSnapshot(frame: frame, tracks: result.active, events: counter.events, fps: fpsEma)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker.reset()
        counter.reset()
        lastFrameTime = 0
        fpsEma = 0
    }

    /// Flush vehicles still inside a zone and return every event of the session.
    func finish(frameAspect: Float) -> [CountEvent] {
        lock.lock(); defer { lock.unlock() }
        counter.finish(zones: zones, frameAspect: frameAspect)
        return counter.events
    }
}
