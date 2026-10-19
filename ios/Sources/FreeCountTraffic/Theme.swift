import SwiftUI
import TrafficCore

/// White UI with an orange accent; pastel box colours and per-class colours shared by every screen.
enum Theme {
    static let orange = Color(red: 0.949, green: 0.541, blue: 0.059)
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

    static func cls(_ c: VehicleClass) -> Color {
        switch c {
        case .car: return Color(red: 0.898, green: 0.451, blue: 0.451)
        case .truck: return Color(red: 0.259, green: 0.647, blue: 0.961)
        case .bus: return Color(red: 1.0, green: 0.792, blue: 0.157)
        case .motorcycle: return Color(red: 0.671, green: 0.278, blue: 0.737)
        case .bicycle: return Color(red: 0.149, green: 0.651, blue: 0.604)
        case .person: return Color(red: 0.553, green: 0.431, blue: 0.388)
        }
    }
}
