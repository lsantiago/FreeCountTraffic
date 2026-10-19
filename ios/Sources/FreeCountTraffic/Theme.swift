import SwiftUI
import TrafficCore
import UIKit

/// White UI with an orange accent; pastel box colours and per-class colours shared by every screen.
enum Theme {
    static let orange = Color(red: 1.0, green: 0.584, blue: 0.0)
    static let peach = Color(red: 1.0, green: 0.945, blue: 0.886)
    static let ink = Color(red: 0.231, green: 0.137, blue: 0.0)

    private static let zones: [Color] = [
        Color(red: 1.00, green: 0.835, blue: 0.310),
        Color(red: 0.392, green: 0.710, blue: 0.965),
        Color(red: 0.937, green: 0.604, blue: 0.604),
        Color(red: 0.506, green: 0.780, blue: 0.518),
        Color(red: 0.729, green: 0.408, blue: 0.784),
    ]

    static func zone(_ index: Int) -> Color { zones[((index % zones.count) + zones.count) % zones.count] }

    /// Same hues as the reference app's class icons: red car, blue truck, yellow bus.
    static func cls(_ c: VehicleClass) -> Color {
        switch c {
        case .car: return Color(red: 0.93, green: 0.33, blue: 0.33)
        case .truck: return Color(red: 0.20, green: 0.53, blue: 0.93)
        case .bus: return Color(red: 0.88, green: 0.72, blue: 0.10)
        case .motorcycle: return Color(red: 0.671, green: 0.278, blue: 0.737)
        case .bicycle: return Color(red: 0.149, green: 0.651, blue: 0.604)
        case .person: return Color(red: 0.553, green: 0.431, blue: 0.388)
        }
    }

    private static let trackPalette: [Color] = [
        Color(red: 0.93, green: 0.33, blue: 0.33), Color(red: 0.20, green: 0.60, blue: 0.86),
        Color(red: 0.61, green: 0.35, blue: 0.71), Color(red: 0.10, green: 0.74, blue: 0.61),
        Color(red: 0.95, green: 0.61, blue: 0.07), Color(red: 0.20, green: 0.29, blue: 0.37),
    ]

    /// Boxes, tags and trails are coloured per tracked vehicle so overlapping ones stay readable.
    static func track(_ id: Int) -> Color { trackPalette[((id % trackPalette.count) + trackPalette.count) % trackPalette.count] }
}

/// SF Symbols used for each class (car / delivery truck / bus ... like the reference app).
enum ClassSymbol {
    static func name(_ c: VehicleClass) -> String {
        switch c {
        case .car: return "car.fill"
        case .truck: return "box.truck.fill"
        case .bus: return "bus.fill"
        case .motorcycle: return firstAvailable(["motorcycle.fill", "motorcycle", "scooter", "bicycle"])
        case .bicycle: return "bicycle"
        case .person: return "figure.walk"
        }
    }

    private static func firstAvailable(_ names: [String]) -> String {
        names.first { UIImage(systemName: $0) != nil } ?? "car.side.fill"
    }
}

struct ClassIcon: View {
    let cls: VehicleClass
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: ClassSymbol.name(cls))
            .font(.system(size: size))
            .foregroundColor(Theme.cls(cls))
            .frame(width: size * 1.4)
    }
}
