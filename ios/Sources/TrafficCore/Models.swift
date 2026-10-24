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
    /// Mean detection confidence of the winning class (0...1).
    public var score: Float

    public init(id: Int, box: RectN, cls: VehicleClass, hits: Int, firstSeenMs: Int64, lastSeenMs: Int64, score: Float = 0) {
        self.id = id
        self.box = box
        self.cls = cls
        self.hits = hits
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
        self.score = score
    }
}

/// One of 8 screen directions (y grows downwards), used to count only the traffic going one way.
public enum Heading: String, CaseIterable, Codable {
    case n, ne, e, se, s, sw, w, nw

    public var arrow: String {
        switch self {
        case .n: return "↑"
        case .ne: return "↗"
        case .e: return "→"
        case .se: return "↘"
        case .s: return "↓"
        case .sw: return "↙"
        case .w: return "←"
        case .nw: return "↖"
        }
    }

    /// Angle in degrees, 0 = east, 90 = south (screen coordinates).
    public var degrees: Float {
        switch self {
        case .e: return 0
        case .se: return 45
        case .s: return 90
        case .sw: return 135
        case .w: return 180
        case .nw: return 225
        case .n: return 270
        case .ne: return 315
        }
    }

    /// True when a movement (in pixel-proportional units) points within `toleranceDeg` of this heading.
    public func accepts(dx: Float, dy: Float, toleranceDeg: Float = 67.5) -> Bool {
        var diff = abs(atan2f(dy, dx) * 180 / .pi - degrees).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff <= toleranceDeg
    }
}

/// A user-drawn counting box. `lengthMeters` is the real-world length along the box's long axis (for speed).
/// `direction` (optional) counts only vehicles moving that way.
public struct Zone: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// The box before rotation (normalized frame coordinates).
    public var rect: RectN
    public var lengthMeters: Float?
    public var direction: Heading?
    /// Clockwise rotation of the box around its centre, in radians (nil = not rotated). The rotation is applied in
    /// pixel space, so the box keeps its shape on screen whatever the frame aspect.
    public var angle: Float?

    public init(id: Int, name: String, rect: RectN, lengthMeters: Float? = nil, direction: Heading? = nil, angle: Float? = nil) {
        self.id = id
        self.name = name
        self.rect = rect
        self.lengthMeters = lengthMeters
        self.direction = direction
        self.angle = angle
    }

    public var rotation: Float { angle ?? 0 }

    /// Unit vector of the box's width axis in pixel-proportional space (x scaled by the frame aspect).
    public var axis: (c: Float, s: Float) { (cosf(rotation), sinf(rotation)) }

    /// A point in the box's own frame: u along its width, v along its height, both within -0.5...0.5 inside the box.
    public func local(_ x: Float, _ y: Float, frameAspect a: Float) -> (u: Float, v: Float) {
        let dx = (x - rect.cx) * a
        let dy = y - rect.cy
        let (c, s) = axis
        let rx = dx * c + dy * s
        let ry = -dx * s + dy * c
        return (rx / max(rect.width * a, 1e-6), ry / max(rect.height, 1e-6))
    }

    public func contains(_ x: Float, _ y: Float, frameAspect: Float) -> Bool {
        if rotation == 0 { return rect.contains(x, y) }
        let p = local(x, y, frameAspect: frameAspect)
        return abs(p.u) <= 0.5 && abs(p.v) <= 0.5
    }
}

/// One counted vehicle. `direction` is an arrow: "→" "←" (horizontal zone) or "↓" "↑" (vertical zone).
/// `timeMs` is the moment the vehicle entered the box, relative to the start of the session.
public struct CountEvent: Codable, Equatable {
    public var zoneId: Int
    public var zoneName: String
    public var trackId: Int
    public var cls: VehicleClass
    public var direction: String
    public var speedKmh: Float?
    public var timeMs: Int64
    public var score: Float?
    /// Axle class picked by a person for a truck (E50 field form); nil = not classified yet.
    public var axle: AxleClass?

    public init(zoneId: Int, zoneName: String, trackId: Int, cls: VehicleClass, direction: String, speedKmh: Float?, timeMs: Int64,
                score: Float? = nil, axle: AxleClass? = nil) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.trackId = trackId
        self.cls = cls
        self.direction = direction
        self.speedKmh = speedKmh
        self.timeMs = timeMs
        self.score = score
        self.axle = axle
    }
}
