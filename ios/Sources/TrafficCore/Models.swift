import Foundation

public enum VehicleClass: String, CaseIterable, Codable, Hashable {
    case car, truck, bus, motorcycle, bicycle, person

    public var label: String {
        switch self {
        case .car: return "Car"
        case .truck: return "Truck"
        case .bus: return "Bus"
        case .motorcycle: return "Motorcycle"
        case .bicycle: return "Bicycle"
        case .person: return "Person"
        }
    }

    /// Maps COCO label names (Darknet/Apple spell motorcycle "motorbike") to a class we count.
    public static func fromCoco(_ name: String) -> VehicleClass? {
        switch name.lowercased() {
        case "car": return .car
        case "truck": return .truck
        case "bus": return .bus
        case "motorcycle", "motorbike": return .motorcycle
        case "bicycle": return .bicycle
        case "person": return .person
        default: return nil
        }
    }
}

/// Axis-aligned rectangle in normalized (0...1) frame coordinates, origin top-left.
public struct RectN: Codable, Equatable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public init(left: Float, top: Float, right: Float, bottom: Float) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Float { right - left }
    public var height: Float { bottom - top }
    public var cx: Float { (left + right) / 2 }
    public var cy: Float { (top + bottom) / 2 }

    public func contains(_ x: Float, _ y: Float) -> Bool {
        x >= left && x <= right && y >= top && y <= bottom
    }

    public func shifted(_ dx: Float, _ dy: Float) -> RectN {
        RectN(left: left + dx, top: top + dy, right: right + dx, bottom: bottom + dy)
    }

    public func iou(_ o: RectN) -> Float {
        let iw = min(right, o.right) - max(left, o.left)
        let ih = min(bottom, o.bottom) - max(top, o.top)
        if iw <= 0 || ih <= 0 { return 0 }
        let inter = iw * ih
        let union = width * height + o.width * o.height - inter
        return union <= 0 ? 0 : inter / union
    }
}

public struct Detection {
    public var box: RectN
    public var cls: VehicleClass
    public var score: Float

    public init(box: RectN, cls: VehicleClass, score: Float) {
        self.box = box
        self.cls = cls
        self.score = score
    }
}

/// Snapshot of a tracked object. Times are milliseconds on the source's clock.
public struct Track: Equatable {
    public var id: Int
    public var box: RectN
    public var cls: VehicleClass
    public var hits: Int
    public var firstSeenMs: Int64
    public var lastSeenMs: Int64

    public init(id: Int, box: RectN, cls: VehicleClass, hits: Int, firstSeenMs: Int64, lastSeenMs: Int64) {
        self.id = id
        self.box = box
        self.cls = cls
        self.hits = hits
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
    }
}

/// A user-drawn counting box. `lengthMeters` is the real-world length along the box's long axis (for speed).
public struct Zone: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var rect: RectN
    public var lengthMeters: Float?

    public init(id: Int, name: String, rect: RectN, lengthMeters: Float? = nil) {
        self.id = id
        self.name = name
        self.rect = rect
        self.lengthMeters = lengthMeters
    }
}

/// One counted vehicle. `direction` is an arrow: "→" "←" (horizontal zone) or "↓" "↑" (vertical zone).
public struct CountEvent: Codable, Equatable {
    public var zoneId: Int
    public var zoneName: String
    public var trackId: Int
    public var cls: VehicleClass
    public var direction: String
    public var speedKmh: Float?
    public var timeMs: Int64

    public init(zoneId: Int, zoneName: String, trackId: Int, cls: VehicleClass, direction: String, speedKmh: Float?, timeMs: Int64) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.trackId = trackId
        self.cls = cls
        self.direction = direction
        self.speedKmh = speedKmh
        self.timeMs = timeMs
    }
}
