import Foundation

/// Truck classes by axles of the E50 field form ("ficha"). The detector only knows "truck": a person picks the class
/// from the vehicle's photo after the session.
public enum AxleClass: String, CaseIterable, Codable {
    case c2g = "C-2G"
    case c34 = "C-3-4"
    case c5 = "C5"
    case c6 = "≥C6"
}

/// Columns of the E50 vehicle count form. Vans are seen as cars and fall in AUTOS/CAMIONETAS, as the form wants.
public enum FichaCategory: String, CaseIterable {
    case autos = "AUTOS/CAMIONETAS"
    case bus = "BUS 2 EJES"
    case c2g = "C-2G"
    case c34 = "C-3-4"
    case c5 = "C5"
    case c6 = "≥C6"
    case motos = "MOTOS"
    case bicicletas = "BICICLETAS"
    case sinClasificar = "SIN CLASIFICAR"

    /// Columns printed on the paper form; bicycles and unclassified trucks are reported in the observations.
    public static let printed: [FichaCategory] = [.autos, .bus, .c2g, .c34, .c5, .c6, .motos]

    /// Category of a counted vehicle (nil for pedestrians).
    public init?(_ e: CountEvent) {
        switch e.cls {
        case .car: self = .autos
        case .bus: self = .bus
        case .motorcycle: self = .motos
        case .bicycle: self = .bicicletas
        case .person: return nil
        case .truck:
            switch e.axle {
            case .c2g: self = .c2g
            case .c34: self = .c34
            case .c5: self = .c5
            case .c6: self = .c6
            case nil: self = .sinClasificar
            }
        }
    }
}

/// A 15-minute period of the form, in ms since local midnight of the session's first day.
public struct FichaPeriod: Equatable {
    public var startOfDayMs: Int64
    public var endOfDayMs: Int64
    /// The session started after the period began or ended before it finished.
    public var partial: Bool
}

/// Counts per movement and period, as the paper form lays them out (one sheet per movement).
public struct FichaTable: Equatable {
    public var movements: [String]
    public var periods: [FichaPeriod]
    /// counts[movement][period][category]
    public var counts: [[[FichaCategory: Int]]]

    public func total(movement m: Int, _ c: FichaCategory) -> Int {
        counts[m].reduce(0) { $0 + ($1[c] ?? 0) }
    }
}

public enum Ficha {
    public static let periodMs: Int64 = 15 * 60 * 1000

    /// Movement of a counted vehicle: its box and the way it went through it ("Zone 1 ↓").
    public static func movement(_ e: CountEvent) -> String { "\(e.zoneName) \(e.direction)" }

    /// - Parameters:
    ///   - dayOffsetMs: ms from local midnight to the start of the session, so periods follow the clock (07:00,
    ///     07:15, …) like the paper form; 0 when the real start time is unknown.
    ///   - zones: box order for the movements; a box with no vehicles still gets its (empty) sheet.
    public static func table(_ events: [CountEvent], zones: [Zone], durationMs: Int64, dayOffsetMs: Int64) -> FichaTable {
        let counted = events.filter { FichaCategory($0) != nil }
        var movements: [String] = []
        for z in zones {
            let own = counted.filter { $0.zoneId == z.id }
            if own.isEmpty {
                movements.append(z.name)
            } else {
                for e in own.sorted(by: { $0.timeMs < $1.timeMs }) where !movements.contains(movement(e)) { movements.append(movement(e)) }
            }
        }
        for e in counted where !movements.contains(movement(e)) { movements.append(movement(e)) }

        let end = max(durationMs, (counted.map { $0.timeMs }.max() ?? 0) + 1)
        let first = dayOffsetMs / periodMs
        let last = max(first, (dayOffsetMs + end - 1) / periodMs)
        let periods = (first...last).map { i -> FichaPeriod in
            let s = i * periodMs
            return FichaPeriod(startOfDayMs: s, endOfDayMs: s + periodMs,
                               partial: dayOffsetMs > s || dayOffsetMs + end < s + periodMs)
        }
        var counts = Array(repeating: Array(repeating: [FichaCategory: Int](), count: periods.count), count: movements.count)
        for e in counted {
            guard let c = FichaCategory(e), let m = movements.firstIndex(of: movement(e)) else { continue }
            let p = Int((dayOffsetMs + max(e.timeMs, 0)) / periodMs - first)
            counts[m][min(p, periods.count - 1)][c, default: 0] += 1
        }
        return FichaTable(movements: movements, periods: periods, counts: counts)
    }
}
