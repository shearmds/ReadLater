import SwiftUI

enum AppTheme: String, CaseIterable {
    case sunset, ocean, forest, dusk, rose, midnight

    var displayName: String {
        switch self {
        case .sunset:   return "Sunset"
        case .ocean:    return "Ocean"
        case .forest:   return "Forest"
        case .dusk:     return "Dusk"
        case .rose:     return "Rose"
        case .midnight: return "Midnight"
        }
    }

    var start: Color {
        switch self {
        case .sunset:   return Color(red: 1.000, green: 0.541, blue: 0.298)
        case .ocean:    return Color(red: 0.149, green: 0.776, blue: 0.855)
        case .forest:   return Color(red: 0.612, green: 0.800, blue: 0.396)
        case .dusk:     return Color(red: 0.671, green: 0.278, blue: 0.737)
        case .rose:     return Color(red: 0.957, green: 0.561, blue: 0.694)
        case .midnight: return Color(red: 0.102, green: 0.137, blue: 0.494)
        }
    }

    var end: Color {
        switch self {
        case .sunset:   return Color(red: 0.925, green: 0.251, blue: 0.478)
        case .ocean:    return Color(red: 0.086, green: 0.396, blue: 0.753)
        case .forest:   return Color(red: 0.180, green: 0.490, blue: 0.196)
        case .dusk:     return Color(red: 0.224, green: 0.286, blue: 0.671)
        case .rose:     return Color(red: 0.773, green: 0.157, blue: 0.157)
        case .midnight: return Color(red: 0.051, green: 0.278, blue: 0.631)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
